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
                return "Sonos GetTransportInfo response is missing transport fields"
            }
        }
    }

    /// Reads transport state only; it does not start, stop, or alter playback.
    public static func getTransportInfo(for receiver: SonosReceiver) async throws -> SonosTransportInfo {
        guard let controlURL = receiver.avTransportControlURL else {
            throw ClientError.missingAVTransportService
        }

        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#GetTransportInfo\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetTransportInfo xmlns:u="\(serviceType)">
              <InstanceID>0</InstanceID>
            </u:GetTransportInfo>
          </s:Body>
        </s:Envelope>
        """.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ClientError.unexpectedHTTPStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

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
}

private final class TransportInfoParser: NSObject, XMLParserDelegate {
    private let expectedElements: Set<String> = [
        "CurrentTransportState", "CurrentTransportStatus", "CurrentSpeed",
    ]
    private var currentElement: String?
    private var currentText = ""
    private var values: [String: String] = [:]

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