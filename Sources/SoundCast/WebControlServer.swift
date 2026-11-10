import Foundation
import Network
import SystemConfiguration

struct WebRequest: Sendable {
    let method: String
    let path: String
    let body: Data
}

struct WebResponse: Sendable {
    var status = 200
    var contentType = "application/json; charset=utf-8"
    var body = Data()
}

/// A minimal HTTP/1.1 server for the web control page: one request per
/// connection, answered by `handler` (which hops to the main actor).
/// Listens on every interface, so any device on the home network can use
/// it — by the user's choice there is no access code.
final class WebControlServer: @unchecked Sendable {
    static let port: UInt16 = 8765

    private let handler: @Sendable (WebRequest) async -> WebResponse
    private let queue = DispatchQueue(label: "com.soundcast.webcontrol")
    private var listener: NWListener?

    init(handler: @escaping @Sendable (WebRequest) async -> WebResponse) {
        self.handler = handler
    }

    /// "http://Ersans-MacBook-Pro.local:8765" — the Mac's Bonjour name.
    static var address: String {
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } ?? "localhost"
        return "http://\(host):\(port)"
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { state in
            NSLog("[SoundCast][Web] listener \(state)")
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var request = buffered
            if let data { request.append(data) }
            if let parsed = Self.parse(request) {
                let handler = self.handler
                Task {
                    let response = await handler(parsed)
                    Self.send(response, on: connection)
                }
            } else if isComplete || error != nil || request.count > 1_000_000 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffered: request)
            }
        }
    }

    /// A complete request (headers plus Content-Length bytes of body), or
    /// nil if more data is needed.
    private static func parse(_ data: Data) -> WebRequest? {
        guard let headerEnd = data.range(of: Data([13, 10, 13, 10])) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let path = String(requestLine[1].split(separator: "?").first ?? "/")
        return WebRequest(method: String(requestLine[0]), path: path, body: Data(data[bodyStart..<bodyStart + contentLength]))
    }

    private static func send(_ response: WebResponse, on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 503: "Service Unavailable"][response.status] ?? "OK"
        var data = Data("""
        HTTP/1.1 \(response.status) \(reason)\r
        Content-Type: \(response.contentType)\r
        Content-Length: \(response.body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
