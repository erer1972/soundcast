import Foundation

public struct SonosTransportInfo: Equatable, Sendable {
    public let currentTransportState: String
    public let currentTransportStatus: String
    public let currentSpeed: String
}

public enum SonosUPnPClient {
    private static let serviceType = "urn:schemas-upnp-org:service:AVTransport:1"

    public enum ClientError: Error, CustomStringConvertible {
        case missingAVTransportService
        case unexpectedHTTPStatus(Int)
        case malformedResponse

        public var description: String {
            switch self {
            case .missingAVTransportService:
                return "Sonos description has no AVTransport control URL"
            case .unexpectedHTTPStatus(let status):
                return "Sonos AVTransport returned HTTP \(status)"
            case .malformedResponse:
                return "Sonos AVTransport response is missing required fields"
            }
        }
    }

    public static func setAVTransportURI(for receiver: SonosReceiver, uri: URL, metadata: String = "") async throws {
        _ = try await performAction(
            "SetAVTransportURI",
            receiver: receiver,
            arguments: [("InstanceID", "0"), ("CurrentURI", uri.absoluteString), ("CurrentURIMetaData", metadata)]
        )
    }

    public static func play(_ receiver: SonosReceiver) async throws {
        _ = try await performAction("Play", receiver: receiver, arguments: [("InstanceID", "0"), ("Speed", "1")], timeout: 20)
    }

    public static func stop(_ receiver: SonosReceiver) async throws {
        _ = try await performAction("Stop", receiver: receiver, arguments: [("InstanceID", "0")])
    }

    public static func pause(_ receiver: SonosReceiver) async throws {
        _ = try await performAction("Pause", receiver: receiver, arguments: [("InstanceID", "0")])
    }

        public static func liveWAVMetadata(uri: URL, sampleRate: UInt32, channels: UInt16 = 2, bitsPerSample: UInt16 = 16) -> String {
                let protocolInfo = "http-get:*:audio/wav:DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=0d500000000000000000000000000000"
                return """
                <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">
                    <item id="1" parentID="0" restricted="1">
                        <dc:title>SoundCast live audio</dc:title>
                        <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>
                        <res protocolInfo="\(protocolInfo)" sampleFrequency="\(sampleRate)" bitsPerSample="\(bitsPerSample)" nrAudioChannels="\(channels)">\(escapeXML(uri.absoluteString))</res>
                    </item>
                </DIDL-Lite>
                """
        }

    /// Reads transport state only; it does not start, stop, or alter playback.
    public static func getTransportInfo(for receiver: SonosReceiver) async throws -> SonosTransportInfo {
        let data = try await performAction("GetTransportInfo", receiver: receiver, arguments: [("InstanceID", "0")])
        let parserDelegate = TransportInfoParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse(),
              let state = parserDelegate.value(for: "CurrentTransportState"),
              let status = parserDelegate.value(for: "CurrentTransportStatus"),
              let speed = parserDelegate.value(for: "CurrentSpeed") else {
            throw ClientError.malformedResponse
        }
        return SonosTransportInfo(
            currentTransportState: state,
            currentTransportStatus: status,
            currentSpeed: speed
        )
    }

    public static func getCurrentURI(for receiver: SonosReceiver) async throws -> String {
        let data = try await performAction("GetMediaInfo", receiver: receiver, arguments: [("InstanceID", "0")])
        let parserDelegate = TransportInfoParser(expectedElements: ["CurrentURI"])
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse(), let uri = parserDelegate.value(for: "CurrentURI") else {
            throw ClientError.malformedResponse
        }
        return uri
    }

    private static func performAction(
        _ action: String,
        receiver: SonosReceiver,
        arguments: [(String, String)],
        timeout: TimeInterval = 3
    ) async throws -> Data {
        guard let controlURL = receiver.avTransportControlURL else {
            throw ClientError.missingAVTransportService
        }

        let argumentXML = arguments.map { name, value in
            "<\(name)>\(escapeXML(value))</\(name)>"
        }.joined()
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(serviceType)">\(argumentXML)</u:\(action)>
          </s:Body>
        </s:Envelope>
        """.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.unexpectedHTTPStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class TransportInfoParser: NSObject, XMLParserDelegate {
    private let expectedElements: Set<String>
    private var currentElement: String?
    private var currentText = ""
    private var values: [String: String] = [:]

    init(expectedElements: Set<String> = ["CurrentTransportState", "CurrentTransportStatus", "CurrentSpeed"]) {
        self.expectedElements = expectedElements
    }

    func value(for element: String) -> String? {
        values[element]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = qName?.split(separator: ":").last.map(String.init) ?? elementName
        guard expectedElements.contains(localName) else {
            currentElement = nil
            return
        }
        currentElement = localName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = qName?.split(separator: ":").last.map(String.init) ?? elementName
        guard currentElement == localName else { return }
        values[localName] = currentText
        currentElement = nil
        currentText = ""
    }
}