import Foundation
import Network

/// A receiver found via Bonjour on `_airplay._tcp` — an Apple TV,
/// HomePod, AirPlay-2-capable speaker (confirmed on this project's own
/// LAN to include at least one Sonos model), or another Mac's AirPlay
/// Receiver. Design doc §12 Phase 2 step 1: discovery + display only —
/// nothing here opens a connection yet (that starts at step 2, pairing).
public struct AirPlayReceiver: Identifiable, Hashable, Sendable {
    /// The "deviceid" TXT field — stable across IP/port changes, unlike
    /// the Bonjour instance name (which the user can rename) or the
    /// resolved host/port (which can change on the LAN).
    public let id: String
    /// The Bonjour instance name, e.g. "Living Room", "kaan" — this is
    /// literally the room name, exactly what the room picker should show.
    public let name: String
    public let model: String?
    /// Best-effort display hint, not a protocol fact: every device seen
    /// on this project's own LAN scan that supports AirPlay 2 grouping
    /// (all three Apple TVs on tvOS 26/27, and the AirPlay-2-capable
    /// Sonos speaker) advertised a "gid" TXT field; devices that can't
    /// group shouldn't have one. Pairing (step 2) will reveal the real
    /// capability — treat this as a label, not a routing decision.
    public let supportsAirPlay2: Bool
    public let endpoint: NWEndpoint

    public init(id: String, name: String, model: String?, supportsAirPlay2: Bool, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.model = model
        self.supportsAirPlay2 = supportsAirPlay2
        self.endpoint = endpoint
    }

    public static func == (lhs: AirPlayReceiver, rhs: AirPlayReceiver) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Browses Bonjour for `_airplay._tcp` receivers so they can be listed as
/// castable rooms in the menu bar, the same way `LocalDeviceEnumerator`
/// lists local Core Audio devices.
///
/// `_raop._tcp` (classic AirPlay 1 / RAOP) is intentionally not browsed
/// separately: every real device seen on this project's own LAN scan
/// advertises both service types for the same physical device, and
/// `_airplay._tcp`'s TXT record alone already carries everything this
/// step needs (model, features, pk, deviceid).
@MainActor
public final class AirPlayDiscovery: ObservableObject {
    @Published public private(set) var receivers: [AirPlayReceiver] = []

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        // Plain `.bonjour(type:domain:)` only resolves endpoints — its
        // Result.metadata always comes back `.none`. `.bonjour(txt)`
        // needs the dedicated `.bonjourWithTXTRecord` descriptor case,
        // confirmed against the real Network.framework swiftinterface
        // on the Mac Pro (plain `.bonjour` found all 4 real receivers on
        // this LAN but with metadata `<none>` for every one of them).
        let newBrowser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: params)
        // The handler's closure type isn't itself @MainActor-isolated
        // (the compiler doesn't know `queue: .main` below means it will
        // always run on the main thread), so hop over explicitly rather
        // than call the main-actor-isolated `apply` directly from here.
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
        receivers = []
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        receivers = results.compactMap { result -> AirPlayReceiver? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            guard case let .bonjour(txt) = result.metadata else { return nil }
            let deviceID = Self.string(txt, "deviceid") ?? name
            let model = Self.string(txt, "model")
            let supportsAirPlay2 = Self.string(txt, "gid") != nil
            return AirPlayReceiver(
                id: deviceID,
                name: name,
                model: model,
                supportsAirPlay2: supportsAirPlay2,
                endpoint: result.endpoint
            )
        }.sorted { $0.name < $1.name }
    }

    private static func string(_ txt: NWTXTRecord, _ key: String) -> String? {
        guard case let .string(value)? = txt.getEntry(for: key) else { return nil }
        return value
    }
}
