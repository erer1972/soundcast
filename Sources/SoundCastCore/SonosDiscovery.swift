import Foundation
import Network

public struct SonosReceiver: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let model: String?
    public let descriptionURL: URL
    public let avTransportControlURL: URL?
    public let renderingControlURL: URL?

    public init(
        id: String,
        name: String,
        model: String?,
        descriptionURL: URL,
        avTransportControlURL: URL?,
        renderingControlURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.descriptionURL = descriptionURL
        self.avTransportControlURL = avTransportControlURL
        self.renderingControlURL = renderingControlURL
    }
}

@MainActor
public final class SonosDiscovery: ObservableObject {
    @Published public private(set) var receivers: [SonosReceiver] = []

    private struct Candidate: Equatable, Sendable {
        let id: String
        let location: URL
    }

    private var browser: NWBrowser?
    private var resolutionTask: Task<Void, Never>?
    private var generation = 0
    private var lastCandidates: [Candidate] = []

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil),
            using: parameters
        )
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.apply(results)
            }
        }
        newBrowser.start(queue: .main)
        browser = newBrowser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        lastCandidates = []
        receivers = []
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var uniqueCandidates: [String: Candidate] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  let id = Self.string(txt, "uuid"),
                  let locationString = Self.string(txt, "location"),
                  let location = URL(string: locationString),
                  location.scheme?.lowercased() == "http" else { continue }
            uniqueCandidates[id] = Candidate(id: id, location: location)
        }
        let candidates = uniqueCandidates.values.sorted { $0.id < $1.id }
        guard candidates != lastCandidates else { return }
        lastCandidates = candidates
        NSLog("[SoundCast][SonosDiscovery] resolving \(candidates.count) unique service(s)")

        generation += 1
        let currentGeneration = generation
        resolutionTask?.cancel()
        resolutionTask = Task { [weak self] in
            var discovered: [SonosReceiver] = []
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                if let receiver = await Self.loadDescription(candidate) {
                    discovered.append(receiver)
                }
            }
            guard let self, self.generation == currentGeneration else { return }
            self.receivers = discovered.sorted { $0.name < $1.name }
            NSLog("[SoundCast][SonosDiscovery] found \(discovered.count) receiver(s)")
        }
    }

    private static func loadDescription(_ candidate: Candidate) async -> SonosReceiver? {
        var request = URLRequest(url: candidate.location)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            NSLog("[SoundCast][SonosDiscovery] description request failed for \(candidate.id)")
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            NSLog("[SoundCast][SonosDiscovery] description response was not HTTP 200 for \(candidate.id)")
            return nil
        }

        let description = SonosDeviceDescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = description
        guard parser.parse() else {
            NSLog("[SoundCast][SonosDiscovery] description XML failed to parse for \(candidate.id): \(String(describing: parser.parserError))")
            return nil
        }
        guard let friendlyName = description.value(for: "friendlyName"), !friendlyName.isEmpty else {
            NSLog("[SoundCast][SonosDiscovery] description has no friendly name for \(candidate.id)")
            return nil
        }
        let model = description.value(for: "modelName")
        let controlURL = description.avTransportControlPath.flatMap {
            URL(string: $0, relativeTo: candidate.location)?.absoluteURL
        }
        let renderingURL = description.renderingControlPath.flatMap {
            URL(string: $0, relativeTo: candidate.location)?.absoluteURL
        }
        return SonosReceiver(
            id: candidate.id,
            name: Self.displayName(friendlyName, model: model),
            model: model,
            descriptionURL: candidate.location,
            avTransportControlURL: controlURL,
            renderingControlURL: renderingURL
        )
    }

    private static func displayName(_ friendlyName: String, model: String?) -> String {
        let parts = friendlyName.components(separatedBy: " - ")
        if parts.count >= 3,
           parts[0].contains("."),
           parts.last?.hasPrefix("RINCON_") == true {
            let name = parts.dropFirst().dropLast().joined(separator: " - ")
            if !name.isEmpty { return name }
        }
        return friendlyName.isEmpty ? (model ?? friendlyName) : friendlyName
    }

    private static func string(_ txt: NWTXTRecord, _ key: String) -> String? {
        guard case let .string(value)? = txt.getEntry(for: key) else { return nil }
        return value
    }
}

private final class SonosDeviceDescriptionParser: NSObject, XMLParserDelegate {
    private let textElements: Set<String> = ["friendlyName", "modelName", "serviceType", "controlURL"]
    private var currentElement: String?
    private var currentText = ""
    private var values: [String: String] = [:]
    private var currentServiceType: String?
    private(set) var avTransportControlPath: String?
    private(set) var renderingControlPath: String?

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
        if elementName == "service" { currentServiceType = nil }
        guard textElements.contains(elementName),
              (elementName != "friendlyName" && elementName != "modelName" || values[elementName] == nil) else {
            currentElement = nil
            return
        }
        currentElement = elementName
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
        if currentElement == elementName {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "friendlyName", "modelName":
                values[elementName] = value
            case "serviceType":
                currentServiceType = value
            case "controlURL" where currentServiceType?.contains(":service:AVTransport:") == true:
                avTransportControlPath = value
            case "controlURL" where currentServiceType?.contains(":service:RenderingControl:") == true:
                renderingControlPath = value
            default:
                break
            }
            currentElement = nil
            currentText = ""
        }
        if elementName == "service" { currentServiceType = nil }
    }
}