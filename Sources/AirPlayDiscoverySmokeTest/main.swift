import Foundation
import SoundCastCore

// Bonjour discovery smoke test for AirPlay receivers, or Sonos UPnP
// descriptions with --sonos. No audio is played.
//
// Usage: AirPlayDiscoverySmokeTest [--sonos] [<seconds, default 8>]

CPUFeatureGuard.logAndGuard(context: "AirPlayDiscoverySmokeTest launch")

var args = Array(CommandLine.arguments.dropFirst())
let discoverSonos = args.first == "--sonos"
if discoverSonos { args.removeFirst() }
let durationSeconds = args.first.flatMap(Double.init) ?? 8.0

let pollInterval = 0.5
if discoverSonos {
    let discovery = SonosDiscovery()
    await discovery.start()
    print("Browsing _sonos._tcp and fetching device descriptions for \(durationSeconds)s...")

    var elapsed = 0.0
    var discovered: [String: SonosReceiver] = [:]
    var transportQueries = 0
    while elapsed < durationSeconds {
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        elapsed += pollInterval
        for receiver in await discovery.receivers where discovered[receiver.id] == nil {
            discovered[receiver.id] = receiver
            let modelText = receiver.model.map { " (\($0))" } ?? ""
            print("    - \(receiver.name)\(modelText) id=\(receiver.id) location=\(receiver.descriptionURL)")
            do {
                let info = try await SonosUPnPClient.getTransportInfo(for: receiver)
                transportQueries += 1
                print("      transport state=\(info.currentTransportState) status=\(info.currentTransportStatus) speed=\(info.currentSpeed)")
            } catch {
                print("      GetTransportInfo failed: \(error)")
            }
        }
    }

    await discovery.stop()
    if discovered.isEmpty {
        print("\nFAIL: discovered zero Sonos receivers with readable UPnP descriptions.")
        exit(1)
    }
    guard transportQueries > 0 else {
        print("\nFAIL: discovered Sonos receivers but GetTransportInfo succeeded for none.")
        exit(1)
    }
    print("\nPASS: discovered \(discovered.count) Sonos receiver(s); GetTransportInfo succeeded for \(transportQueries).")
    exit(0)
}

let discovery = AirPlayDiscovery()
await discovery.start()
print("Browsing _airplay._tcp for \(durationSeconds)s...")

var elapsed = 0.0
var lastCount = -1
while elapsed < durationSeconds {
    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    elapsed += pollInterval
    let found = await discovery.receivers
    if found.count != lastCount {
        lastCount = found.count
        print("  [t=\(elapsed)s] \(found.count) receiver(s):")
        for receiver in found {
            let badge = receiver.supportsAirPlay2 ? "AirPlay2" : "AirPlay1"
            let modelText = receiver.model.map { " (\($0))" } ?? ""
            print("    - \(receiver.name)\(modelText) [\(badge)] id=\(receiver.id)")
        }
    }
}

let finalReceivers = await discovery.receivers
await discovery.stop()

if finalReceivers.isEmpty {
    print("\nFAIL: discovered zero AirPlay receivers — expected to find at least one on this LAN.")
    exit(1)
} else {
    print("\nPASS: discovered \(finalReceivers.count) AirPlay receiver(s) via Bonjour.")
    exit(0)
}
