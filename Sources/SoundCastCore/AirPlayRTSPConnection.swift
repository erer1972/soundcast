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

    private let connection: NWConnection
    private var cseq: Int = 0
    private var receiveBuffer = Data()

    public init(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        connection = NWConnection(host: host, port: port, using: .tcp)
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: ConnectionError.connectFailed("\(error)"))
                case .cancelled:
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: requestData, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ConnectionError.sendFailed("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }

        return try await receiveResponse()
    }

    private func receiveResponse() async throws -> Response {
        while true {
            if let response = try parseBufferedResponse() {
                return response
            }
            let chunk = try await receiveChunk()
            receiveBuffer.append(chunk)
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
