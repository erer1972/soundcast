import AudioToolbox
import CoreAudio
import Foundation
import SoundCastCore

// Autonomous(-ish) smoke test for the full Phase 1 pipeline: real system
// audio capture (ProcessTapCapture) chained straight into real local
// multi-output (LocalOutputEngine) — i.e. "play whatever's on the Mac
// out of every ticked device," end to end, from one CLI run instead of
// clicking through the menu bar UI.
//
// Unlike LocalOutputSmokeTest, this DOES need the one-time system
// audio-capture consent prompt (only capturing needs it; rendering
// doesn't) — that part genuinely needs a human physically present to
// click Allow. Running this without that consent granted yet is still
// useful: it tells us whether the denied/not-yet-decided path fails
// cleanly (a proper Core Audio error we can catch and report) rather
// than crashing, which is real signal either way.
//
// Usage:
//   CaptureSmokeTest [<seconds, default 8>] [<device-uid> ...]

CPUFeatureGuard.logAndGuard(context: "CaptureSmokeTest launch")

let allDevices = LocalDeviceEnumerator.listOutputDevices()
print("Discovered \(allDevices.count) local output device(s):")
for device in allDevices {
    print("  [\(device.category.rawValue)] \(device.name)  uid=\(device.id)")
}

var args = Array(CommandLine.arguments.dropFirst())
var durationSeconds: Double = 8.0
if let first = args.first, let parsed = Double(first) {
    durationSeconds = parsed
    args.removeFirst()
}

let requestedUIDs = Set(args)
let targetDevices = requestedUIDs.isEmpty ? allDevices : allDevices.filter { requestedUIDs.contains($0.id) }

guard !targetDevices.isEmpty else {
    print("No matching devices to render to. Exiting.")
    exit(1)
}

print("\nCapturing system audio and rendering to: \(targetDevices.map(\.name).joined(separator: ", "))")
print("If this is the first time, macOS should now show a system-audio capture permission prompt.")
print("That needs a human to click Allow on the actual screen — this process will wait for it.\n")

let ringBuffer = RingBuffer(capacitySamples: 48_000 * 2 * 4) // a bit more headroom than the output-only test

let capture = ProcessTapCapture(ringBuffer: ringBuffer)
let output = LocalOutputEngine(sourceRingBuffer: ringBuffer)
let targets = targetDevices.map { LocalOutputEngine.Target(device: $0, gain: 1.0) }

do {
    try capture.start()
    print("Process tap + capture aggregate device started OK (permission already granted, or just granted).")
    try output.reconfigure(targets: targets)
    print("Local output aggregate + IOProc started OK.")
    print("Running for \(durationSeconds)s — play some audio on the Mac now (e.g. a YouTube video) to hear it routed through.")
    Thread.sleep(forTimeInterval: durationSeconds)
    output.stop()
    capture.stop()
    print("\nPASS: captured system audio and rendered it to the selected device(s) with no Core Audio error.")
    print("Human check still needed: did audio actually play on the Mac during the test, and did you hear it come out the selected device(s)?")
    exit(0)
} catch {
    output.stop()
    capture.stop()
    print("\nFAIL: \(error)")
    print("If this is 'failedToCreateTap' or similar on a first run, it may mean the permission")
    print("prompt was denied, dismissed, or never answered — check System Settings > Privacy &")
    print("Security > Microphone for a SoundCast/CaptureSmokeTest entry and try again.")
    exit(1)
}
