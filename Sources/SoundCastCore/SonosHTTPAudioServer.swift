import Darwin
import Foundation

/// Serves one live stereo PCM stream as WAV over HTTP.
/// The caller owns a dedicated ring buffer for this receiver.
public final class SonosHTTPAudioServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case invalidSampleRate(Double)
        case invalidPeerAddress(String)
        case socketFailure(String, Int32)
        case alreadyRunning

        public var description: String {
            switch self {
            case .invalidSampleRate(let rate): return "unsupported WAV sample rate \(rate)"
            case .invalidPeerAddress(let address): return "invalid Sonos IPv4 address \(address)"
            case .socketFailure(let operation, let code): return "\(operation) failed (errno \(code))"
            case .alreadyRunning: return "Sonos HTTP audio server is already running"
            }
        }
    }

    private static let chunkFrames = 960
    private static let waveLength: UInt32 = 2_147_483_644
    private let source: RingBuffer
    private let sampleRate: Double
    private let delaySeconds: Double
    private let onStreamInterrupted: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var listenerSocket: Int32 = -1
    private var running = false
    private var clients: Set<Int32> = []

    public init(source: RingBuffer, sampleRate: Double, delaySeconds: Double = 0, onStreamInterrupted: (@Sendable () -> Void)? = nil) {
        self.source = source
        self.sampleRate = sampleRate
        self.delaySeconds = delaySeconds.isFinite ? max(0, min(10, delaySeconds)) : 0
        self.onStreamInterrupted = onStreamInterrupted
    }

    /// Starts an HTTP listener on the interface routed to the Sonos and
    /// returns a URL the Sonos can use as its AVTransport current URI.
    public func start(peerIPv4: String) throws -> URL {
        guard beginStart() else { throw ServerError.alreadyRunning }
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            stop()
            throw ServerError.invalidSampleRate(sampleRate)
        }

        guard let localAddress = Self.routeSelectedLocalAddress(to: peerIPv4) else {
            stop()
            throw ServerError.invalidPeerAddress(peerIPv4)
        }

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ServerError.socketFailure("socket", errno) }
        var reuse: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        guard localAddress.withCString({ inet_pton(AF_INET, $0, &local.sin_addr) }) == 1 else {
            Darwin.close(socket)
            throw ServerError.invalidPeerAddress(localAddress)
        }
        let bindResult = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(socket)
            throw ServerError.socketFailure("bind", code)
        }
        guard Darwin.listen(socket, 8) == 0 else {
            let code = errno
            Darwin.close(socket)
            throw ServerError.socketFailure("listen", code)
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            let code = errno
            Darwin.close(socket)
            throw ServerError.socketFailure("getsockname", code)
        }
        let port = UInt16(bigEndian: bound.sin_port)
        setListener(socket)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(socket)
        }

        guard let url = URL(string: "http://\(localAddress):\(port)/stream.wav") else {
            stop()
            throw ServerError.invalidPeerAddress(localAddress)
        }
        NSLog("[SoundCast][SonosHTTPAudioServer] listening on port \(port)")
        return url
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let listener = listenerSocket
        listenerSocket = -1
        let activeClients = Array(clients)
        clients.removeAll()
        lock.unlock()

        if listener >= 0 {
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        for client in activeClients { _ = Darwin.shutdown(client, SHUT_RDWR) }
    }

    public func disconnectClientsForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        for client in clients { _ = Darwin.shutdown(client, SHUT_RDWR) }
        return clients.count
    }

    private func acceptLoop(_ listener: Int32) {
        NSLog("[SoundCast][SonosHTTPAudioServer] accept loop started")
        while isRunning {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, 1_000)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                if isRunning { NSLog("[SoundCast][SonosHTTPAudioServer] poll failed (errno \(errno))") }
                return
            }
            guard descriptor.revents & Int16(POLLIN) != 0 else { continue }

            var address = sockaddr_in()
            var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listener, $0, &addressLength)
                }
            }
            guard client >= 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if isRunning { NSLog("[SoundCast][SonosHTTPAudioServer] accept failed (errno \(errno))") }
                return
            }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            lock.lock()
            let shouldServe = running
            if shouldServe { clients.insert(client) }
            lock.unlock()
            guard shouldServe else { Darwin.close(client); return }
            NSLog("[SoundCast][SonosHTTPAudioServer] accepted client")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer {
            lock.lock()
            clients.remove(client)
            lock.unlock()
            Darwin.close(client)
        }
        guard let request = readRequest(client),
              let requestLine = request.components(separatedBy: "\r\n").first else { return }
                NSLog("[SoundCast][SonosHTTPAudioServer] request: \(requestLine)")
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { return }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: \(Self.waveLength)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        if fields[0] == "HEAD", fields[1] == "/stream.wav" {
            _ = sendAll(client, Data(response.utf8))
            return
        }
        guard fields[0] == "GET", fields[1] == "/stream.wav" else {
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = sendAll(client, Data(response.utf8))
            return
        }

        guard sendAll(client, Data(response.utf8)), sendAll(client, Self.waveHeader(sampleRate: UInt32(sampleRate.rounded()))) else { return }
        var peak: Float = 0
        var chunks = 0
        var remaining = Int(Self.waveLength) - 44
        var silentFrames = Int(sampleRate * delaySeconds)
        var nextDeadline = ProcessInfo.processInfo.systemUptime
        defer { NSLog("[SoundCast][SonosHTTPAudioServer] stream ended: \(chunks) chunks, peak \(peak)") }
        while isRunning && remaining > 0 {
            var samples = [Float](repeating: 0, count: Self.chunkFrames * 2)
            let silent = min(silentFrames, Self.chunkFrames)
            silentFrames -= silent
            if silent < Self.chunkFrames {
                samples.withUnsafeMutableBufferPointer {
                    source.read(into: $0.baseAddress!.advanced(by: silent * 2), count: $0.count - silent * 2)
                }
            }
            for sample in samples where sample.isFinite { peak = max(peak, abs(sample)) }
            let data = Self.pcm16(samples)
            let count = min(remaining, data.count)
            guard sendAll(client, Data(data.prefix(count))) else {
                if chunks >= 150 && isRunning { onStreamInterrupted?() }
                return
            }
            remaining -= count
            chunks += 1
            nextDeadline += Double(Self.chunkFrames) / sampleRate
            let delay = nextDeadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
    }

    private func readRequest(_ client: Int32) -> String? {
        let terminator = Data("\r\n\r\n".utf8)
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while request.count < 8192, request.range(of: terminator) == nil {
            let received = buffer.withUnsafeMutableBytes { Darwin.recv(client, $0.baseAddress!, $0.count, 0) }
            guard received > 0 else { return nil }
            request.append(contentsOf: buffer.prefix(received))
        }
        return String(data: request, encoding: .utf8)
    }

    private func sendAll(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return data.isEmpty }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.send(client, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return false }
                sent += result
            }
            return true
        }
    }

    private func beginStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func setListener(_ socket: Int32) {
        lock.lock()
        listenerSocket = socket
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private static func routeSelectedLocalAddress(to peerIPv4: String) -> String? {
        var peer = sockaddr_in()
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_family = sa_family_t(AF_INET)
        guard peerIPv4.withCString({ inet_pton(AF_INET, $0, &peer.sin_addr) }) == 1 else { return nil }
        return AirPlayPTPClock.routeSelectedIPv4(to: peer)
    }

    private func routeSelectedLocalAddress(to peerIPv4: String) -> String? {
        Self.routeSelectedLocalAddress(to: peerIPv4)
    }

    private static func waveHeader(sampleRate: UInt32) -> Data {
        var header = Data("RIFF".utf8)
        appendLittleEndian(waveLength - 8, to: &header)
        header.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(UInt16(2), to: &header)
        appendLittleEndian(sampleRate, to: &header)
        appendLittleEndian(sampleRate * 4, to: &header)
        appendLittleEndian(UInt16(4), to: &header)
        appendLittleEndian(UInt16(16), to: &header)
        header.append(Data("data".utf8))
        appendLittleEndian(waveLength - 44, to: &header)
        return header
    }

    private static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for (index, sample) in samples.enumerated() {
                let finiteSample = sample.isFinite ? sample : 0
                let clamped = max(-1, min(1, finiteSample))
                let value = UInt16(bitPattern: Int16((clamped * 32767).rounded()))
                bytes[index * 2] = UInt8(truncatingIfNeeded: value)
                bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
            }
        }
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}