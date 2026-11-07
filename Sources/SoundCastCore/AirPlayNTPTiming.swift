import Darwin
import Foundation

/// NTP-style timing for native AirPlay 2 realtime streams, as used by
/// OwnTones by default (`timingProtocol: "NTP"` plus a `timingPort` in
/// the session SETUP). The receiver sends 32-byte `0x80 0xD2` timing
/// requests to `port`; we answer with `0x80 0xD3` carrying receive and
/// transmit times. Sync packets (`0xD4`) sent on the control channel tie
/// RTP positions to the same clock.
public final class AirPlayNTPTiming: @unchecked Sendable {
    public enum TimingError: Error {
        case invalidPeerAddress(String)
        case interfaceHasNoHardwareAddress(String)
        case socketFailure(Int32)
    }

    public let localAddress: String
    public let deviceID: String
    public let port: UInt16

    private let socket: Int32
    private let queue = DispatchQueue(label: "SoundCast.AirPlayNTPTiming")
    private var source: DispatchSourceRead?
    private var requests = 0

    /// Seconds between 1900-01-01 (NTP epoch) and 1970-01-01.
    private static let ntpEpochDelta: UInt64 = 2_208_988_800

    public init(peerIPv4: String) throws {
        var peer = in_addr()
        guard peerIPv4.withCString({ inet_pton(AF_INET, $0, &peer) }) == 1 else {
            throw TimingError.invalidPeerAddress(peerIPv4)
        }
        var peerSocketAddress = sockaddr_in()
        peerSocketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peerSocketAddress.sin_family = sa_family_t(AF_INET)
        peerSocketAddress.sin_addr = peer
        guard let localAddress = AirPlayPTPClock.routeSelectedIPv4(to: peerSocketAddress) else {
            throw TimingError.invalidPeerAddress(peerIPv4)
        }
        guard let hardwareAddress = AirPlayPTPClock.hardwareAddress(for: localAddress) else {
            throw TimingError.interfaceHasNoHardwareAddress(localAddress)
        }
        self.localAddress = localAddress
        deviceID = hardwareAddress.map { String(format: "%02X", $0) }.joined(separator: ":")

        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw TimingError.socketFailure(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard bindResult == 0, nameResult == 0 else {
            let error = errno
            Darwin.close(socket)
            throw TimingError.socketFailure(error)
        }
        let flags = fcntl(socket, F_GETFL)
        if flags >= 0 { _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK) }
        self.socket = socket
        port = UInt16(bigEndian: bound.sin_port)
    }

    public func start() {
        queue.sync {
            guard source == nil else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [weak self] in self?.receive() }
            source.setCancelHandler { [socket] in Darwin.close(socket) }
            source.resume()
            self.source = source
        }
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
        }
    }

    public var requestCount: Int { queue.sync { requests } }

    /// A 20-byte `0xD4` sync packet: `currentPosition` is the RTP frame
    /// that should be audible at the NTP time written into the packet
    /// (now), `nextTimestamp` the next RTP timestamp to be sent. Layout
    /// from OwnTones' `sync_packet_ntp_make`.
    public func syncPacket(currentPosition: UInt32, nextTimestamp: UInt32, first: Bool) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 20)
        packet[0] = first ? 0x90 : 0x80
        packet[1] = 0xD4
        packet[2] = 0x00
        packet[3] = 0x07
        Self.write32(currentPosition, to: &packet, at: 4)
        Self.write64(Self.nowNTP(), to: &packet, at: 8)
        Self.write32(nextTimestamp, to: &packet, at: 16)
        return packet
    }

    private func receive() {
        while true {
            var request = [UInt8](repeating: 0, count: 64)
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let receiveTime = Self.nowNTP()
            let received = request.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socket, bytes.baseAddress, bytes.count, 0, $0, &sourceLength)
                    }
                }
            }
            guard received >= 0 else { return }
            guard received == 32, request[0] == 0x80, request[1] == 0xD2 else { continue }
            requests += 1

            var response = [UInt8](repeating: 0, count: 32)
            response[0] = 0x80
            response[1] = 0xD3
            response[2] = request[2]
            response.replaceSubrange(8..<16, with: request[24..<32]) // echo client's transmit time
            Self.write64(receiveTime, to: &response, at: 16)
            Self.write64(Self.nowNTP(), to: &response, at: 24)
            _ = response.withUnsafeBytes { bytes in
                withUnsafePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socket, bytes.baseAddress, bytes.count, 0, $0, sourceLength)
                    }
                }
            }
        }
    }

    /// 64-bit NTP timestamp (32.32 fixed point) from `CLOCK_REALTIME`.
    /// Any monotonic-ish clock works as long as replies and sync packets
    /// share it; realtime keeps it comparable with the PTP path.
    static func nowNTP() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        let seconds = UInt64(time.tv_sec) + ntpEpochDelta
        let fraction = (UInt64(time.tv_nsec) << 32) / 1_000_000_000
        return (seconds << 32) | fraction
    }

    private static func write32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (24 - 8 * index)) & 0xFF) }
    }

    private static func write64(_ value: UInt64, to bytes: inout [UInt8], at offset: Int) {
        for index in 0..<8 { bytes[offset + index] = UInt8((value >> (56 - 8 * index)) & 0xFF) }
    }
}
