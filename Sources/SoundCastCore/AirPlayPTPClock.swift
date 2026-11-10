import Darwin
import Foundation

/// Minimal single-peer PTP grandmaster for native AirPlay 2 smoke tests.
/// It advertises one clock and answers the receiver's Delay_Req,
/// Pdelay_Req, and unicast signaling messages.
public final class AirPlayPTPClock: @unchecked Sendable {
    public struct ProbeCounts {
        public let delayRequests: Int
        public let peerDelayRequests: Int
        public let signalingRequests: Int
        public let signalingGrants: Int
        public let requestedMessageTypes: [UInt8: Int]
    }

    public let localAddress: String
    public let deviceID: String
    public let peerID = UUID().uuidString
    public let clockIdentity: UInt64

    /// Receivers this clock is grandmaster for. One clock per process,
    /// since UDP 319/320 can only be bound once; each AirPlay session
    /// adds its receiver and removes it on teardown.
    private var peers: [sockaddr_in] = []
    /// Sessions using each peer (keyed by s_addr). A reconnect can add
    /// the same receiver before the old session's teardown removes it,
    /// so removal only takes effect when the last user is gone.
    private var peerUsers: [in_addr_t: Int] = [:]
    private let eventSocket: Int32
    private let generalSocket: Int32
    private let queue = DispatchQueue(label: "SoundCast.AirPlayPTPClock")
    private var eventSource: DispatchSourceRead?
    private var generalSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var running = false
    private var announceSequence: UInt16 = 0
    private var signalingSequence: UInt16 = 0
    private var syncSequence: UInt16 = 0
    private var lastAnnounceNs: UInt64 = 0
    private var delayRequests = 0
    private var peerDelayRequests = 0
    private var signalingRequests = 0
    private var signalingGrants = 0
    private var requestedMessageTypes: [UInt8: Int] = [:]

    public enum ClockError: Error {
        case interfaceHasNoIPv4Address(String)
        case interfaceHasNoHardwareAddress(String)
        case invalidPeerAddress(String)
        case socketFailure(Int32)
    }

    public init(peerIPv4: String) throws {
        var peer = in_addr()
        guard peerIPv4.withCString({ inet_pton(AF_INET, $0, &peer) }) == 1 else {
            throw ClockError.invalidPeerAddress(peerIPv4)
        }
        var peerSocketAddress = sockaddr_in()
        peerSocketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peerSocketAddress.sin_family = sa_family_t(AF_INET)
        peerSocketAddress.sin_addr = peer
        peers = [peerSocketAddress]
        guard let localAddress = Self.routeSelectedIPv4(to: peerSocketAddress) else {
            throw ClockError.invalidPeerAddress(peerIPv4)
        }
        self.localAddress = localAddress
        guard let hardwareAddress = Self.hardwareAddress(for: localAddress) else {
            throw ClockError.interfaceHasNoHardwareAddress(localAddress)
        }
        deviceID = hardwareAddress.map { String(format: "%02X", $0) }.joined(separator: ":")
        clockIdentity = Self.eui64(from: hardwareAddress)

        let eventSocket = try Self.openSocket(port: 319, localAddress: localAddress)
        do {
            generalSocket = try Self.openSocket(port: 320, localAddress: localAddress)
        } catch {
            Darwin.close(eventSocket)
            throw error
        }
        self.eventSocket = eventSocket
    }

    /// Adds a receiver (IPv4 literal) to the set this clock serves.
    public func addPeer(ipv4: String) throws {
        let address = try Self.socketAddress(ipv4)
        queue.sync {
            peerUsers[address.sin_addr.s_addr, default: 0] += 1
            guard !peers.contains(where: { $0.sin_addr.s_addr == address.sin_addr.s_addr }) else { return }
            peers.append(address)
            if running {
                sendAnnounce(to: address)
                sendSignaling(to: address)
            }
        }
    }

    public func removePeer(ipv4: String) {
        guard let address = try? Self.socketAddress(ipv4) else { return }
        queue.sync {
            let key = address.sin_addr.s_addr
            let remaining = max(0, (peerUsers[key] ?? 0) - 1)
            peerUsers[key] = remaining == 0 ? nil : remaining
            if remaining == 0 { peers.removeAll { $0.sin_addr.s_addr == key } }
        }
    }

    public var peerCount: Int { queue.sync { peers.count } }

    private static func socketAddress(_ ipv4: String) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard ipv4.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw ClockError.invalidPeerAddress(ipv4)
        }
        return address
    }

    /// Current time on this clock, in nanoseconds (what `0xD7` anchors use).
    public static func now() -> UInt64 { nowNanoseconds() }

    public var timingPeerInfo: [String: Any] {
        [
            "ID": peerID,
            "DeviceType": 0,
            "ClockID": Int64(bitPattern: clockIdentity),
            "SupportsClockPortMatchingOverride": false,
            "Addresses": [localAddress],
        ]
    }

    public func start() {
        queue.sync {
            guard !running else { return }
            running = true

            let eventSource = DispatchSource.makeReadSource(fileDescriptor: eventSocket, queue: queue)
            eventSource.setEventHandler { [weak self] in self?.receive(on: self?.eventSocket ?? -1) }
            eventSource.resume()
            self.eventSource = eventSource

            let generalSource = DispatchSource.makeReadSource(fileDescriptor: generalSocket, queue: queue)
            generalSource.setEventHandler { [weak self] in self?.receive(on: self?.generalSocket ?? -1) }
            generalSource.resume()
            self.generalSource = generalSource

            sendAnnounce()
            sendSignaling()
            sendSync()
            lastAnnounceNs = Self.nowNanoseconds()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(125), repeating: .milliseconds(125))
            timer.setEventHandler { [weak self] in
                guard let self, self.running else { return }
                sendSync()
                let now = Self.nowNanoseconds()
                // Wall-clock time: it can step backwards (time sync), so
                // never subtract a later value from an earlier one.
                if now < lastAnnounceNs || now - lastAnnounceNs >= 1_000_000_000 {
                    sendAnnounce()
                    sendSignaling()
                    lastAnnounceNs = now
                }
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            timer?.cancel()
            eventSource?.cancel()
            generalSource?.cancel()
            timer = nil
            eventSource = nil
            generalSource = nil
            Darwin.close(eventSocket)
            Darwin.close(generalSocket)
        }
    }

    public func probeCounts() -> ProbeCounts {
        queue.sync {
            ProbeCounts(
                delayRequests: delayRequests,
                peerDelayRequests: peerDelayRequests,
                signalingRequests: signalingRequests,
                signalingGrants: signalingGrants,
                requestedMessageTypes: requestedMessageTypes
            )
        }
    }

    public func realtimeSyncPacket(
        rtpTimestamp: UInt32,
        sampleRate: UInt32 = 44_100,
        leadMilliseconds: UInt32 = 2_000,
        first: Bool
    ) -> [UInt8] {
        // Matches OwnTones' sync_packet_ptp_make (a sender that works with
        // Apple TVs): frame1 is the RTP position that plays at the time in
        // bytes 8..<16; frame2 is the next RTP timestamp to send minus
        // 11025. With a 2 s lead that makes frame2 - frame1 = 77175, the
        // value Shairport Sync expects.
        let leadFrames = UInt32((UInt64(leadMilliseconds) * UInt64(sampleRate)) / 1_000)
        let frame1 = rtpTimestamp &- leadFrames
        let frame2 = rtpTimestamp &- 11_025
        var packet = [UInt8](repeating: 0, count: 28)
        packet[0] = first ? 0x90 : 0x80
        packet[1] = 0xD7
        packet[3] = 0x06
        writeUInt32(frame1, to: &packet, at: 4)
        // Bytes 8..<16 are a plain big-endian u64 nanosecond count on the
        // PTP clock (Shairport Sync rtp.c reads them with nctoh64), not a
        // 10-byte PTP 48+32 timestamp. A 10-byte write here produced an
        // anchor time decades off and spilled into frame2.
        writeUInt64(Self.nowNanoseconds(), to: &packet, at: 8)
        writeUInt32(frame2, to: &packet, at: 16)
        writeUInt64(clockIdentity, to: &packet, at: 20)
        return packet
    }

    private func receive(on socket: Int32) {
        guard socket >= 0 else { return }
        while true {
            var packet = [UInt8](repeating: 0, count: 512)
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = packet.withUnsafeMutableBytes { packetBytes in
                withUnsafeMutablePointer(to: &source) { sourcePointer in
                    sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socket, packetBytes.baseAddress, packetBytes.count, 0, $0, &sourceLength)
                    }
                }
            }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                return
            }
            guard received >= 34 else { continue }
            packet.removeSubrange(Int(received)..<packet.count)
            switch packet[0] & 0x0F {
            case 1 where received >= 44:
                delayRequests += 1
                sendDelayResponse(to: source, request: packet)
            case 2 where received >= 44:
                peerDelayRequests += 1
                sendPeerDelayResponse(to: source, request: packet)
            case 12 where received >= 48:
                signalingRequests += 1
                sendUnicastGrant(to: source, request: packet)
            default:
                break
            }
        }
    }

    private func sendAnnounce() {
        for peer in peers { sendAnnounce(to: peer) }
        announceSequence &+= 1
    }

    private func sendAnnounce(to peer: sockaddr_in) {
        var packet = header(type: 0x0B, length: 76, flags: 0x0408,
                            sequence: announceSequence, control: 0, logInterval: 0)
        packet[47] = 128
        packet[48] = 6
        packet[49] = 0x21
        writeUInt16(0x436A, to: &packet, at: 50)
        packet[52] = 128
        writeUInt64(clockIdentity, to: &packet, at: 53)
        packet[63] = 0x20
        writeUInt16(0x0008, to: &packet, at: 64)
        writeUInt16(8, to: &packet, at: 66)
        writeUInt64(clockIdentity, to: &packet, at: 68)
        send(packet, socket: generalSocket, to: peer, port: 320)
    }

    private func sendSignaling() {
        for peer in peers { sendSignaling(to: peer) }
        signalingSequence &+= 1
    }

    private func sendSignaling(to peer: sockaddr_in) {
        var packet = [UInt8](repeating: 0, count: 106)
        writeHeader(type: 0x0C, length: 106, flags: 0x0408,
                    sequence: signalingSequence, control: 0x05, logInterval: -128,
                    to: &packet)
        writeUInt16(0x0003, to: &packet, at: 44)
        writeUInt16(22, to: &packet, at: 46)
        packet[48...53] = [0x00, 0x0D, 0x93, 0x00, 0x00, 0x01]
        packet[54...57] = [0x00, 0x00, 0x03, 0x01]
        writeUInt16(0x0003, to: &packet, at: 70)
        writeUInt16(32, to: &packet, at: 72)
        packet[74...79] = [0x00, 0x0D, 0x93, 0x00, 0x00, 0x05]
        packet[80...83] = [0x00, 0x00, 0x03, 0x01]
        send(packet, socket: generalSocket, to: peer, port: 320)
    }

    private func sendSync() {
        let sequence = syncSequence
        var sync = header(type: 0, length: 44, flags: 0x0608,
                          sequence: sequence, control: 0, logInterval: -3)
        let zeroTimestamp = [UInt8](repeating: 0, count: 10)
        sync.replaceSubrange(34..<44, with: zeroTimestamp)
        for peer in peers { send(sync, socket: eventSocket, to: peer, port: 319) }

        var followUp = header(type: 8, length: 96, flags: 0x0408,
                              sequence: sequence, control: 0, logInterval: -3)
        writeTimestamp(Self.nowNanoseconds(), to: &followUp, at: 34)
        writeUInt16(0x0003, to: &followUp, at: 44)
        writeUInt16(28, to: &followUp, at: 46)
        followUp[48...53] = [0x00, 0x80, 0xC2, 0x00, 0x00, 0x01]
        writeUInt16(0x0003, to: &followUp, at: 76)
        writeUInt16(16, to: &followUp, at: 78)
        followUp[80...85] = [0x00, 0x0D, 0x93, 0x00, 0x00, 0x04]
        writeUInt64(clockIdentity, to: &followUp, at: 86)
        for peer in peers { send(followUp, socket: generalSocket, to: peer, port: 320) }
        syncSequence &+= 1
    }

    private func sendDelayResponse(to source: sockaddr_in, request: [UInt8]) {
        let sequence = readUInt16(request, at: 30)
        var packet = header(type: 9, length: 54, flags: 0x0608,
                            sequence: sequence, control: 0, logInterval: -3)
        writeTimestamp(Self.nowNanoseconds(), to: &packet, at: 34)
        packet.replaceSubrange(44..<54, with: request[20..<30])
        send(packet, socket: generalSocket, to: source, port: 320)
    }

    private func sendPeerDelayResponse(to source: sockaddr_in, request: [UInt8]) {
        let sequence = readUInt16(request, at: 30)
        var response = header(type: 3, length: 54, flags: 0x0608,
                              sequence: sequence, control: 0, logInterval: -3)
        writeTimestamp(Self.nowNanoseconds(), to: &response, at: 34)
        response.replaceSubrange(44..<54, with: request[20..<30])
        send(response, socket: eventSocket, to: source, port: 319)

        var followUp = header(type: 0x0A, length: 54, flags: 0x0408,
                              sequence: sequence, control: 0, logInterval: -3)
        writeTimestamp(Self.nowNanoseconds(), to: &followUp, at: 34)
        followUp.replaceSubrange(44..<54, with: request[20..<30])
        send(followUp, socket: generalSocket, to: source, port: 320)
    }

    private func sendUnicastGrant(to source: sockaddr_in, request: [UInt8]) {
        var grants: [[UInt8]] = []
        var offset = 44
        while offset + 4 <= request.count {
            let type = readUInt16(request, at: offset)
            let length = Int(readUInt16(request, at: offset + 2))
            guard offset + 4 + length <= request.count else { break }
            if type == 4, length >= 6 {
                let messageType = request[offset + 4] >> 4
                requestedMessageTypes[messageType, default: 0] += 1
                var grant: [UInt8] = [0x00, 0x05, 0x00, 0x08]
                grant.append(request[offset + 4])
                grant.append(request[offset + 5])
                grant.append(contentsOf: request[(offset + 6)..<(offset + 10)])
                grant.append(0)
                grant.append(1)
                grants.append(grant)
            }
            offset += 4 + length
        }
        guard !grants.isEmpty else { return }
        signalingGrants += grants.count
        let length = 44 + grants.reduce(0) { $0 + $1.count }
        var reply = header(type: 0x0C, length: length, flags: 0x0400,
                           sequence: readUInt16(request, at: 30), control: 0x05,
                           logInterval: 0x7F)
        reply.replaceSubrange(34..<44, with: request[20..<30])
        var replyOffset = 44
        for grant in grants {
            reply.replaceSubrange(replyOffset..<(replyOffset + grant.count), with: grant)
            replyOffset += grant.count
        }
        send(reply, socket: generalSocket, to: source, port: 320)
    }

    private func header(type: UInt8, length: Int, flags: UInt16, sequence: UInt16,
                        control: UInt8, logInterval: Int8) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: length)
        writeHeader(type: type, length: length, flags: flags, sequence: sequence,
                    control: control, logInterval: logInterval, to: &packet)
        return packet
    }

    private func writeHeader(type: UInt8, length: Int, flags: UInt16, sequence: UInt16,
                             control: UInt8, logInterval: Int8, to packet: inout [UInt8]) {
        packet[0] = 0x10 | (type & 0x0F)
        packet[1] = 2
        writeUInt16(UInt16(length), to: &packet, at: 2)
        packet[4] = 0
        writeUInt16(flags, to: &packet, at: 6)
        writeUInt64(clockIdentity, to: &packet, at: 20)
        packet[28] = 0x80
        packet[29] = 0x05
        writeUInt16(sequence, to: &packet, at: 30)
        packet[32] = control
        packet[33] = UInt8(bitPattern: logInterval)
    }

    private func send(_ packet: [UInt8], socket: Int32, to destination: sockaddr_in, port: UInt16) {
        var destination = destination
        destination.sin_port = port.bigEndian
        let sent = packet.withUnsafeBytes { packetBytes in
            withUnsafePointer(to: &destination) { destinationPointer in
                destinationPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, packetBytes.baseAddress, packetBytes.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent != packet.count {
            let reason = String(cString: strerror(errno))
            // A receiver that's off the network fails every send (~15/s);
            // log the first failure, then at most a summary every 30 s.
            let now = DispatchTime.now().uptimeNanoseconds
            let summary = sendFailureLock.withLock { () -> Int? in
                sendFailuresSinceLog += 1
                guard now &- lastSendFailureLog >= 30_000_000_000 || lastSendFailureLog == 0 else { return nil }
                defer { sendFailuresSinceLog = 0; lastSendFailureLog = now }
                return sendFailuresSinceLog
            }
            if let summary {
                NSLog("[SoundCast][AirPlayPTP] UDP send failed: \(reason) (\(summary) failure(s) since last report)")
            }
        }
    }

    private let sendFailureLock = NSLock()
    private var sendFailuresSinceLog = 0
    private var lastSendFailureLog: UInt64 = 0

    private static func openSocket(port: UInt16, localAddress: String) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw ClockError.socketFailure(errno) }
        var reuse: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse,
                       socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = errno
            Darwin.close(socket)
            throw ClockError.socketFailure(error)
        }

        var membership = ip_mreq()
        membership.imr_multiaddr.s_addr = "224.0.1.129".withCString { inet_addr($0) }
        guard localAddress.withCString({ inet_pton(AF_INET, $0, &membership.imr_interface) }) == 1 else {
            Darwin.close(socket)
            throw ClockError.interfaceHasNoIPv4Address(localAddress)
        }
        _ = setsockopt(socket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership,
                       socklen_t(MemoryLayout<ip_mreq>.size))

        let flags = fcntl(socket, F_GETFL)
        if flags >= 0 { _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK) }
        return socket
    }

    static func routeSelectedIPv4(to peer: sockaddr_in) -> String? {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return nil }
        defer { Darwin.close(socket) }

        var peer = peer
        peer.sin_port = UInt16(320).bigEndian
        let connectResult = withUnsafePointer(to: &peer) { peerPointer in
            peerPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &local) { localPointer in
            localPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }
        guard nameResult == 0 else { return nil }

        var address = local.sin_addr
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &output, socklen_t(output.count)) != nil else { return nil }
        let end = output.firstIndex(of: 0) ?? output.endIndex
        let bytes = output[..<end].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Name of the local interface that owns `ipv4Address` (e.g. "en0").
    static func interfaceName(forLocalIPv4 ipv4Address: String) -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            let item = interface.pointee
            if let address = item.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                var inAddress = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &inAddress, &output, socklen_t(output.count)) != nil,
                   String(nulTerminated: output) == ipv4Address {
                    return String(cString: item.ifa_name)
                }
            }
            current = item.ifa_next
        }
        return nil
    }

    static func hardwareAddress(for ipv4Address: String) -> [UInt8]? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }
        var interfaceName: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            let item = interface.pointee
            if let address = item.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                var address = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address, &output, socklen_t(output.count)) != nil {
                    let end = output.firstIndex(of: 0) ?? output.endIndex
                    let bytes = output[..<end].map { UInt8(bitPattern: $0) }
                    if String(decoding: bytes, as: UTF8.self) == ipv4Address {
                        interfaceName = String(cString: item.ifa_name)
                        break
                    }
                }
            }
            current = item.ifa_next
        }
        guard let interfaceName else { return nil }

        current = first
        while let interface = current {
            let item = interface.pointee
            if String(cString: item.ifa_name) == interfaceName,
               let address = item.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK) {
                let linkAddress = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
                let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(linkAddress.sdl_nlen)
                let data = UnsafeRawPointer(address).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                let bytes = Array(UnsafeBufferPointer(start: data, count: Int(linkAddress.sdl_alen)))
                return bytes.count == 6 ? bytes : nil
            }
            current = item.ifa_next
        }
        return nil
    }

    private static func eui64(from macAddress: [UInt8]) -> UInt64 {
        (UInt64(macAddress[0]) << 56) | (UInt64(macAddress[1]) << 48) |
        (UInt64(macAddress[2]) << 40) | (UInt64(0xFF) << 32) |
        (UInt64(0xFE) << 24) | (UInt64(macAddress[3]) << 16) |
        (UInt64(macAddress[4]) << 8) | UInt64(macAddress[5])
    }

    private static func nowNanoseconds() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    private func writeTimestamp(_ ns: UInt64, to packet: inout [UInt8], at offset: Int) {
        let seconds = ns / 1_000_000_000
        let nanoseconds = UInt32(ns % 1_000_000_000)
        for index in 0..<6 { packet[offset + index] = UInt8((seconds >> (40 - 8 * index)) & 0xFF) }
        for index in 0..<4 { packet[offset + 6 + index] = UInt8((nanoseconds >> (24 - 8 * index)) & 0xFF) }
    }

    private func writeUInt16(_ value: UInt16, to packet: inout [UInt8], at offset: Int) {
        packet[offset] = UInt8((value >> 8) & 0xFF)
        packet[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeUInt32(_ value: UInt32, to packet: inout [UInt8], at offset: Int) {
        packet[offset] = UInt8((value >> 24) & 0xFF)
        packet[offset + 1] = UInt8((value >> 16) & 0xFF)
        packet[offset + 2] = UInt8((value >> 8) & 0xFF)
        packet[offset + 3] = UInt8(value & 0xFF)
    }

    private func writeUInt64(_ value: UInt64, to packet: inout [UInt8], at offset: Int) {
        for index in 0..<8 { packet[offset + index] = UInt8((value >> (56 - 8 * index)) & 0xFF) }
    }

    private func readUInt16(_ packet: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(packet[offset]) << 8) | UInt16(packet[offset + 1])
    }
}