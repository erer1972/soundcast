import Foundation
import SoundCastCore

// Design doc §12 Phase 2 step 1 smoke test: Bonjour discovery only — no
// pairing or connection yet. Prints every _airplay._tcp receiver found,
// with real TXT-derived fields, as direct evidence discovery works
// end-to-end on real hardware — not just "no exception was thrown".
//
// Usage: AirPlayDiscoverySmokeTest [<seconds, default 8>]

CPUFeatureGuard.logAndGuard(context: "AirPlayDiscoverySmokeTest launch")

let args = Array(CommandLine.arguments.dropFirst())
let durationSeconds = args.first.flatMap(Double.init) ?? 8.0

let discovery = AirPlayDiscovery()
await discovery.start()
print("Browsing _airplay._tcp for \(durationSeconds)s...")

var elapsed = 0.0
let pollInterval = 0.5
var lastCount = -1
while elapsed < durationSeconds {
    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    elapsed += pollInterval
    let found = await discovery.receivers
    if found.count != lastCount {
        lastCount = found.count
        print("  [t=\(String(format: "%.1f", elapsed))s] \(found.count) receiver(s):")
        for r in found {
            let badge = r.supportsAirPlay2 ? "AirPlay2" : "AirPlay1"
            let modelText = r.model.map { " (\($0))" } ?? ""
            print("    - \(r.name)\(modelText) [\(badge)] id=\(r.id)")
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
