import CryptoKit
import Foundation
import Network

/// A minimal RTSP-over-TCP client for one AirPlay control connection:
/// sends one request at a time and waits for its response, framed by
/// Content-Length — confirmed against a real capture of macOS's own
/// AirPlay sender (design doc §12), which pipelined GET /info and three
/// POST /pair-verify round trips over exactly this shape on one
/// connection, each request immediately followed by its own response
/// before the next request went out. Shared by pair-verify, pair-setup,
/// and (Phase 2 step 3) RTSP SETUP/RECORD — AirPlay multiplexes all of
/// these over the same single TCP connection to port 7000.
///
/// Not marked @MainActor; its methods are only ever meant to be awaited
/// one at a time by a single caller, so the mutable `receiveBuffer` and
/// `cseq` are never genuinely accessed concurrently — same reasoning as
/// the `@unchecked Sendable` state-holder classes elsewhere in this
/// package (e.g. VirtualDeviceCapture's PollState).
public final class AirPlayRTSPConnection: @unchecked Sendable {
    public struct Response {
        public let statusCode: Int
        public let headers: [String: String]
        public let body: [UInt8]
    }

    public enum ConnectionError: Error {
        case connectFailed(String)
        case sendFailed(String)
        case receiveFailed(String)
        case malformedResponse
    }

    /// Headers real AirPlay senders send on every pair-setup/pair-verify
    /// request — confirmed necessary the hard way: a bare
    /// Content-Type-only request got a `500` with an empty body from a
    /// real Apple TV; adding these three made it respond normally
    /// (`200`, real TLV8 M2 body) instead. `X-Apple-HKP` picks the
    /// "HomeKit Pairing" protocol version — the real capture this
    /// session showed macOS try `6` first and fall back to `3` when an
    /// older Apple TV rejected it; going straight to `3` here is a
    /// deliberate simplification until HKP 6 is itself verified.
    public static let pairingHeaders: [String: String] = [
        "Content-Type": "application/octet-stream",
        "X-Apple-HKP": "3",
        "X-Apple-Client-Name": "SoundCast",
        "X-Apple-PD": "1",
    ]

    /// Per-direction state for the encrypted channel pair-verify unlocks.
    /// Framing (per public research, not yet independently verified
    /// against a live encrypted exchange the way pairing was): each
    /// frame is a 2-byte little-endian plaintext length (itself used as
    /// AAD), up to 1024 bytes of ChaCha20-Poly1305 ciphertext, then a
    /// 16-byte Poly1305 tag. The nonce is 4 zero bytes followed by an
    /// 8-byte little-endian counter that increments once per frame, kept
    /// separately per direction.
    private struct EncryptionState {
        let readKey: SymmetricKey
        let writeKey: SymmetricKey
        var readCounter: UInt64 = 0
        var writeCounter: UInt64 = 0
    }

    private let connection: NWConnection
    private var cseq: Int = 0
    private var receiveBuffer = Data()
    private var rawReceiveBuffer = Data()
    private var encryption: EncryptionState?

    public init(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        connection = NWConnection(host: host, port: port, using: .tcp)
    }

    public func connect() async throws {
        // NWConnection can report a terminal state (e.g. .failed) more
        // than once for the same attempt — resume exactly once
        // regardless (see AirPlayAudioStream.connect()'s identical
        // guard, added after this exact double-resume crashed the
        // process live).
        final class ResumeGuard: @unchecked Sendable {
            var didResume = false
        }
        let resumeGuard = ResumeGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard !resumeGuard.didResume else { return }
                switch state {
                case .ready:
                    resumeGuard.didResume = true
                    continuation.resume()
                case .failed(let error):
                    resumeGuard.didResume = true
                    continuation.resume(throwing: ConnectionError.connectFailed("\(error)"))
                case .cancelled:
                    resumeGuard.didResume = true
                    continuation.resume(throwing: ConnectionError.connectFailed("cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    public func close() {
        connection.cancel()
    }

    /// Diagnostic only: logs whatever bytes arrive on this connection
    /// without otherwise consuming/parsing them, for investigating
    /// connections (like the event connection SETUP phase 1 opens) this
    /// client never normally reads from.
    public func startDiagnosticLogging(label: String) {
        func loop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    FileHandle.standardError.write("[\(label)] receive error: \(error)\n".data(using: .utf8)!)
                    return
                }
                if let data, !data.isEmpty {
                    FileHandle.standardError.write("[\(label)] received \(data.count) bytes: \(data.map { String(format: "%02x", $0) }.joined())\n".data(using: .utf8)!)
                    if let text = String(data: data, encoding: .utf8) {
                        FileHandle.standardError.write("[\(label)] as text: \(text)\n".data(using: .utf8)!)
                    }
                }
                if isComplete {
                    FileHandle.standardError.write("[\(label)] connection closed by peer\n".data(using: .utf8)!)
                    return
                }
                loop()
            }
        }
        loop()
    }

    /// Switches this connection to the encrypted framing pair-verify's
    /// session keys unlock. Call once, right after a successful
    /// pair-verify; every `send()` after this point is transparently
    /// encrypted/decrypted.
    public func enableEncryption(readKey: SymmetricKey, writeKey: SymmetricKey) {
        encryption = EncryptionState(readKey: readKey, writeKey: writeKey)
    }

    private func encryptedNonce(counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Splits `data` into <=1024-byte chunks and encrypts each into one
    /// wire frame: 2-byte little-endian length (used as AAD) + ciphertext
    /// + 16-byte tag.
    private func encryptFrames(_ data: Data) throws -> Data {
        guard var state = encryption else { return data }
        var out = Data()
        var offset = 0
        while offset < data.count {
            let chunkEnd = min(offset + 1024, data.count)
            let chunk = data[offset..<chunkEnd]
            let lengthLE = UInt16(chunk.count).littleEndian
            let lengthBytes = withUnsafeBytes(of: lengthLE) { Data($0) }
            let sealed = try ChaChaPoly.seal(chunk, using: state.writeKey, nonce: encryptedNonce(counter: state.writeCounter), authenticating: lengthBytes)
            out.append(lengthBytes)
            out.append(sealed.ciphertext)
            out.append(contentsOf: sealed.tag)
            state.writeCounter += 1
            offset = chunkEnd
        }
        encryption = state
        return out
    }

    /// Decrypts as many complete frames as `rawReceiveBuffer` currently
    /// holds, appending their plaintext to `receiveBuffer`. Leaves any
    /// trailing partial frame in `rawReceiveBuffer` for next time.
    private func decryptAvailableFrames() throws {
        guard var state = encryption else { return }
        while rawReceiveBuffer.count >= 2 {
            let lengthBytes = Data(rawReceiveBuffer.prefix(2))
            let length = Int(lengthBytes[lengthBytes.startIndex]) | (Int(lengthBytes[lengthBytes.startIndex + 1]) << 8)
            let frameTotal = 2 + length + 16
            guard rawReceiveBuffer.count >= frameTotal else { return }
            let ciphertext = rawReceiveBuffer[(rawReceiveBuffer.startIndex + 2)..<(rawReceiveBuffer.startIndex + 2 + length)]
            let tag = rawReceiveBuffer[(rawReceiveBuffer.startIndex + 2 + length)..<(rawReceiveBuffer.startIndex + frameTotal)]
            let box = try ChaChaPoly.SealedBox(nonce: encryptedNonce(counter: state.readCounter), ciphertext: ciphertext, tag: tag)
            let plaintext = try ChaChaPoly.open(box, using: state.readKey, authenticating: Data(lengthBytes))
            receiveBuffer.append(plaintext)
            state.readCounter += 1
            rawReceiveBuffer.removeSubrange(rawReceiveBuffer.startIndex..<(rawReceiveBuffer.startIndex + frameTotal))
        }
        encryption = state
    }

    @discardableResult
    public func send(
        method: String,
        path: String,
        extraHeaders: [String: String] = [:],
        body: [UInt8] = []
    ) async throws -> Response {
        cseq += 1
        var headerLines = [
            "\(method) \(path) RTSP/1.0",
            "CSeq: \(cseq)",
            "User-Agent: AirPlay/409.16",
        ]
        if !body.isEmpty {
            headerLines.append("Content-Length: \(body.count)")
        }
        for (key, value) in extraHeaders {
            headerLines.append("\(key): \(value)")
        }
        let requestText = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var requestData = Data(requestText.utf8)
        requestData.append(Data(body))
        requestData = try encryptFrames(requestData)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: requestData, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ConnectionError.sendFailed("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }

        let response = try await receiveResponse()
        if ProcessInfo.processInfo.environment["SOUNDCAST_RTSP_TRACE"] != nil {
            FileHandle.standardError.write(Data("[RTSP] \(method) \(path) -> \(response.statusCode)\n".utf8))
        }
        return response
    }

    private func receiveResponse() async throws -> Response {
        while true {
            if let response = try parseBufferedResponse() {
                return response
            }
            let chunk = try await receiveChunk()
            if encryption != nil {
                rawReceiveBuffer.append(chunk)
                try decryptAvailableFrames()
            } else {
                receiveBuffer.append(chunk)
            }
        }
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: ConnectionError.receiveFailed("\(error)"))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ConnectionError.receiveFailed("connection closed"))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func parseBufferedResponse() throws -> Response? {
        guard let headerEndRange = receiveBuffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = receiveBuffer[..<headerEndRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ConnectionError.malformedResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw ConnectionError.malformedResponse }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw ConnectionError.malformedResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["Content-Length"] ?? "0") ?? 0
        let bodyStart = headerEndRange.upperBound
        guard receiveBuffer.count >= bodyStart + contentLength else { return nil }
        let body = Array(receiveBuffer[bodyStart..<(bodyStart + contentLength)])
        receiveBuffer.removeSubrange(..<(bodyStart + contentLength))
        return Response(statusCode: statusCode, headers: headers, body: body)
    }
}
