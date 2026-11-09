import Darwin
import Foundation
import Network

/// Serves one live stereo PCM stream as WAV over HTTP.
/// The caller owns a dedicated ring buffer for this receiver.
public final class SonosHTTPAudioServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case invalidSampleRate(Double)
        case invalidPeerAddress(String)
        case listenerFailure(String)
        case alreadyRunning

        public var description: String {
            switch self {
            case .invalidSampleRate(let rate): return "unsupported WAV sample rate \(rate)"
            case .invalidPeerAddress(let address): return "invalid Sonos IPv4 address \(address)"
            case .listenerFailure(let reason): return "Sonos HTTP listener failed: \(reason)"
            case .alreadyRunning: return "Sonos HTTP audio server is already running"
            }
        }
    }

    private static let chunkFrames = 960
    private static let reserveSeconds = 0.2
    private static let waveLength: UInt32 = 2_147_483_644
    private let source: RingBuffer
    private let sampleRate: Double
    private let delaySeconds: Double
    private let onStreamInterrupted: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var listener: NWListener?
    private var running = false
    private var clients: [UUID: NWConnection] = [:]
    private var streamClient: UUID?
    private var streamClientIsReceiver = false
    private var testUnavailableUntil: TimeInterval?

    public init(
        source: RingBuffer,
        sampleRate: Double,
        delaySeconds: Double = 0,
        onStreamInterrupted: (@Sendable () -> Void)? = nil
    ) {
        self.source = source
        self.sampleRate = sampleRate
        self.delaySeconds = delaySeconds.isFinite ? max(0, min(10, delaySeconds)) : 0
        self.onStreamInterrupted = onStreamInterrupted
    }

    /// Starts an HTTP listener on the interface routed to the Sonos and
    /// returns a URL the Sonos can use as its AVTransport current URI.
    public func start(peerIPv4: String) async throws -> URL {
        guard beginStart() else { throw ServerError.alreadyRunning }
        var started = false
        defer { if !started { stop() } }
        try Self.validateSampleRate(sampleRate)

        guard let localAddress = Self.routeSelectedLocalAddress(to: peerIPv4),
              let localIPv4 = IPv4Address(localAddress) else {
            throw ServerError.invalidPeerAddress(peerIPv4)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localIPv4), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerError.listenerFailure(String(describing: error))
        }

        setListener(listener)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, receiverIPv4: peerIPv4)
        }

        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let gate = ListenerStartGate(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port,
                          let url = URL(string: "http://\(localAddress):\(port.rawValue)/stream.wav") else {
                        gate.resume(.failure(ServerError.listenerFailure("listener has no bound port")))
                        return
                    }
                    gate.resume(.success(url))
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    gate.resume(.failure(ServerError.listenerFailure(String(describing: error))))
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    gate.resume(.failure(ServerError.listenerFailure("listener cancelled during startup")))
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
        }

        NSLog("[SoundCast][SonosHTTPAudioServer] listening on port \(url.port ?? 0)")
        started = true
        return url
    }

    static func validateSampleRate(_ sampleRate: Double) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw ServerError.invalidSampleRate(sampleRate)
        }
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let listener = self.listener
        self.listener = nil
        let activeClients = Array(clients.values)
        clients.removeAll()
        streamClient = nil
        streamClientIsReceiver = false
        testUnavailableUntil = nil
        lock.unlock()

        listener?.cancel()
        for connection in activeClients { connection.cancel() }
    }

    public func disconnectClientsForTesting(unavailableSeconds: TimeInterval = 0) -> Int {
        lock.lock()
        if unavailableSeconds.isFinite, unavailableSeconds > 0 {
            testUnavailableUntil = ProcessInfo.processInfo.systemUptime + min(unavailableSeconds, 30)
        }
        let activeClients = Array(clients.values)
        lock.unlock()
        for connection in activeClients { connection.cancel() }
        return activeClients.count
    }

    private func accept(_ connection: NWConnection, receiverIPv4: String) {
        let clientID = UUID()
        let isReceiver: Bool
        if case .hostPort(let host, _ ) = connection.endpoint,
           let address = IPv4Address(receiverIPv4) {
            isReceiver = host == .ipv4(address)
        } else {
            isReceiver = false
        }

        lock.lock()
        let shouldServe = running
        if shouldServe { clients[clientID] = connection }
        lock.unlock()
        guard shouldServe else {
            connection.cancel()
            return
        }

        NSLog("[SoundCast][SonosHTTPAudioServer] accepted client")
        let receiveGate = ConnectionReceiveGate()
        connection.stateUpdateHandler = { [weak self] state in
            NSLog("[SoundCast][SonosHTTPAudioServer] client state: \(state)")
            switch state {
            case .ready:
                guard receiveGate.claim() else { return }
                self?.receiveRequest(clientID, connection: connection, data: Data(), isReceiver: isReceiver)
            case .failed, .cancelled:
                self?.removeClient(clientID)
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func receiveRequest(
        _ clientID: UUID,
        connection: NWConnection,
        data: Data,
        isReceiver: Bool
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] newData, _, isComplete, error in
            NSLog("[SoundCast][SonosHTTPAudioServer] received \(newData?.count ?? 0) request byte(s), complete=\(isComplete), error=\(String(describing: error))")
            guard let self else {
                connection.cancel()
                return
            }
            var request = data
            if let newData { request.append(newData) }
            let terminator = Data([13, 10, 13, 10])
            if request.range(of: terminator) != nil {
                guard let text = String(data: request, encoding: .utf8),
                      let requestLine = text.components(separatedBy: "\r\n").first else {
                    self.sendAndClose(clientID, connection: connection, response: Self.errorResponse(400, "Bad Request"))
                    return
                }
                self.serve(
                    clientID, connection: connection, requestLine: requestLine,
                    rangeStart: Self.rangeStart(in: text), isReceiver: isReceiver
                )
            } else if error != nil || isComplete || request.count >= 8192 {
                connection.cancel()
            } else {
                self.receiveRequest(clientID, connection: connection, data: request, isReceiver: isReceiver)
            }
        }
    }

    private func serve(_ clientID: UUID, connection: NWConnection, requestLine: String, rangeStart: Int?, isReceiver: Bool) {
        NSLog("[SoundCast][SonosHTTPAudioServer] request: \(requestLine)\(rangeStart.map { " (range from \($0))" } ?? "")")
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else {
            sendAndClose(clientID, connection: connection, response: Self.errorResponse(400, "Bad Request"))
            return
        }

        // After a dropped connection the Sonos reconnects by itself with
        // "Range: bytes=N-" to resume. Answer that with 206 and live audio
        // from now on; a 200 from offset 0 makes it reset the connection.
        let total = Int(Self.waveLength)
        let start = rangeStart.flatMap { (1..<total).contains($0) ? $0 : nil } ?? 0
        let response: String
        if start > 0 {
            response = "HTTP/1.1 206 Partial Content\r\nContent-Type: audio/wav\r\nContent-Range: bytes \(start)-\(total - 1)/\(total)\r\nContent-Length: \(total - start)\r\nAccept-Ranges: bytes\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        } else {
            response = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: \(total)\r\nAccept-Ranges: bytes\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        }
        if fields[0] == "HEAD", fields[1] == "/stream.wav" {
            sendAndClose(clientID, connection: connection, response: response)
            return
        }
        guard fields[0] == "GET", fields[1] == "/stream.wav" else {
            sendAndClose(clientID, connection: connection, response: Self.errorResponse(404, "Not Found"))
            return
        }
        if isReceiver && isTestUnavailable {
            NSLog("[SoundCast][SonosHTTPAudioServer] test outage: rejecting receiver request")
            sendAndClose(clientID, connection: connection, response: Self.errorResponse(503, "Service Unavailable", retryAfter: true))
            return
        }
        guard claimStream(clientID, isReceiver: isReceiver) else {
            sendAndClose(clientID, connection: connection, response: Self.errorResponse(503, "Service Unavailable"))
            return
        }

        var header = Data(response.utf8)
        let waveHeader = Self.waveHeader(sampleRate: UInt32(sampleRate.rounded()))
        var bodyPrefix = 0
        if start < waveHeader.count {
            header.append(waveHeader.suffix(from: start))
            bodyPrefix = waveHeader.count - start
        } else {
            // Pad a partial frame with zeros so later samples stay aligned.
            let partialFrame = (4 - (start - waveHeader.count) % 4) % 4
            header.append(Data(count: partialFrame))
            bodyPrefix = partialFrame
        }
        let audioBytes = total - start - bodyPrefix
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.streamAudio(clientID, connection: connection, audioBytes: audioBytes, isReceiver: isReceiver)
            }
        })
    }

    private func streamAudio(_ clientID: UUID, connection: NWConnection, audioBytes: Int, isReceiver: Bool) {
        var peak: Float = 0
        var chunks = 0
        var remaining = audioBytes
        var silentFrames = Int(sampleRate * delaySeconds)
        var shortChunks = 0
        defer { NSLog("[SoundCast][SonosHTTPAudioServer] stream ended: \(chunks) chunks, \(shortChunks) short, peak \(peak)") }

        // Start from a small reserve: the capture arrives in ~5 ms bursts
        // while this loop sends exact 20 ms chunks, so without one, chunks
        // regularly came up short and were padded with silence (stutter).
        // Older backlog is dropped so the speaker isn't needlessly late.
        let reserveSamples = Int(sampleRate * Self.reserveSeconds) * 2
        source.trim(toAtMost: reserveSamples)
        let prefillDeadline = ProcessInfo.processInfo.systemUptime + 1
        while isRunning && source.framesAvailable < reserveSamples
                && ProcessInfo.processInfo.systemUptime < prefillDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        var nextDeadline = ProcessInfo.processInfo.systemUptime

        while isRunning && remaining > 0 {
            var samples = [Float](repeating: 0, count: Self.chunkFrames * 2)
            let silent = min(silentFrames, Self.chunkFrames)
            silentFrames -= silent
            // If the reserve ran dry, give the next capture burst a moment
            // rather than padding this chunk with silence.
            let needed = (Self.chunkFrames - silent) * 2
            var waited = 0.0
            while isRunning && source.framesAvailable < needed && waited < 0.04 {
                Thread.sleep(forTimeInterval: 0.002)
                waited += 0.002
            }
            if source.framesAvailable < needed { shortChunks += 1 }
            let status = samples.withUnsafeMutableBufferPointer {
                readStream(clientID, into: $0.baseAddress!.advanced(by: silent * 2), count: $0.count - silent * 2)
            }
            switch status {
            case .current:
                break
            case .replaced:
                return
            case .lost:
                // The connection closed underneath us (NWConnection reports
                // .failed/.cancelled before a send fails), so treat it like a
                // failed send rather than a deliberate handover.
                if chunks >= 150 && isReceiver && isRunning { onStreamInterrupted?() }
                connection.cancel()
                return
            }
            for sample in samples where sample.isFinite { peak = max(peak, abs(sample)) }
            let encoded = Self.pcm16(samples)
            let count = min(remaining, encoded.count)
            let result = NWSendResult()
            connection.send(content: Data(encoded.prefix(count)), completion: .contentProcessed { error in
                result.finish(error == nil)
            })
            guard result.wait() else {
                if chunks >= 150 && isReceiver && isRunning { onStreamInterrupted?() }
                connection.cancel()
                return
            }
            remaining -= count
            chunks += 1
            nextDeadline += Double(Self.chunkFrames) / sampleRate
            let delay = nextDeadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        connection.cancel()
    }

    private func sendAndClose(_ clientID: UUID, connection: NWConnection, response: String) {
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Start offset of a "Range: bytes=N-" request header, if any.
    private static func rangeStart(in request: String) -> Int? {
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "range" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard value.hasPrefix("bytes="),
                  let first = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).first else { return nil }
            return Int(first)
        }
        return nil
    }

    private static func errorResponse(_ code: Int, _ reason: String, retryAfter: Bool = false) -> String {
        let retry = retryAfter ? "Retry-After: 1\r\n" : ""
        return "HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\n\(retry)Connection: close\r\n\r\n"
    }

    private func claimStream(_ clientID: UUID, isReceiver: Bool) -> Bool {
        lock.lock()
        guard running, isReceiver || !streamClientIsReceiver else {
            lock.unlock()
            return false
        }
        let previous = streamClient.flatMap { clients[$0] }
        if let previousID = streamClient, previousID != clientID { clients[previousID] = nil }
        streamClient = clientID
        streamClientIsReceiver = isReceiver
        lock.unlock()
        previous?.cancel()
        return true
    }

    private enum StreamStatus { case current, replaced, lost }

    private func readStream(_ clientID: UUID, into output: UnsafeMutablePointer<Float>, count: Int) -> StreamStatus {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return .replaced }
        guard streamClient == clientID else { return streamClient == nil ? .lost : .replaced }
        if count > 0 { source.read(into: output, count: count) }
        return .current
    }

    private func removeClient(_ clientID: UUID) {
        lock.lock()
        clients[clientID] = nil
        if streamClient == clientID {
            streamClient = nil
            streamClientIsReceiver = false
        }
        lock.unlock()
    }

    private var isTestUnavailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return testUnavailableUntil.map { ProcessInfo.processInfo.systemUptime < $0 } == true
    }

    private func beginStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func setListener(_ listener: NWListener) {
        lock.lock()
        self.listener = listener
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

private final class ListenerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: CheckedContinuation<URL, Error>
    private var completed = false

    init(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class NWSendResult: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var succeeded = false

    func finish(_ succeeded: Bool) {
        lock.lock()
        self.succeeded = succeeded
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> Bool {
        guard semaphore.wait(timeout: .now() + 2) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }
}

private final class ConnectionReceiveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

