import Foundation
import SoundCastCore

// Autonomous smoke test for the Phase 1.5 pipeline: reads real audio
// from the HAL driver's shared-memory ring buffer (anything sent to the
// system-wide "SoundCast" virtual output device) and renders it to the
// selected local device(s) via LocalOutputEngine — the Swift-side half
// of design doc §7.1 that CaptureSmokeTest's equivalent covers for the
// global-tap path.
//
// Needs NO privacy consent (reading our own driver's shared memory, and
// rendering audio, are both unprivileged) — fully autonomous, unlike
// CaptureSmokeTest. Requires the SoundCast.driver to be installed and
// something to actually be sending it audio during the test window
// (e.g. this same test run with the Mac's default output temporarily
// pointed at "SoundCast" and something playing, same as
// HALPlugin/test_shm_flow.c already proved works at the driver level).
//
// Usage:
//   VirtualDeviceSmokeTest [--preset=N (0=main, 1-4=presets, default 0)] [<seconds, default 8>] [<device-uid> ...]

CPUFeatureGuard.logAndGuard(context: "VirtualDeviceSmokeTest launch")

let allDevices = LocalDeviceEnumerator.listOutputDevices()
print("Discovered \(allDevices.count) local output device(s):")
for device in allDevices {
    print("  [\(device.category.rawValue)] \(device.name)  uid=\(device.id)")
}

var args = Array(CommandLine.arguments.dropFirst())
var preset = VirtualDevicePreset.main
if let presetArgIndex = args.firstIndex(where: { $0.hasPrefix("--preset=") }) {
    let value = args[presetArgIndex].replacingOccurrences(of: "--preset=", with: "")
    let index = Int(value) ?? 0
    preset = (0..<VirtualDevicePreset.all.count).contains(index) ? VirtualDevicePreset.all[index] : .main
    args.remove(at: presetArgIndex)
}
print("Using virtual device: \(preset.displayName) (\(preset.deviceUID))")

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

print("\nReading SoundCast virtual-device audio, rendering to: \(targetDevices.map(\.name).joined(separator: ", "))")

let ringBuffer = RingBuffer(capacitySamples: 48_000 * 2 * 4)
let capture = VirtualDeviceCapture(ringBuffer: ringBuffer, preset: preset)
let output = LocalOutputEngine(sourceRingBuffer: ringBuffer)
let targets = targetDevices.map { LocalOutputEngine.Target(device: $0, gain: 1.0) }

do {
    try capture.start()
    print("Shared-memory reader started OK (header validated against expected driver layout).")
    try output.reconfigure(targets: targets)
    print("Local output aggregate + IOProc started OK.")
    print("Running for \(durationSeconds)s — send audio to the \"SoundCast\" device now (e.g. set it as default output and play something) to hear it routed through.")
    // Direct evidence of real data flow, not just "no exception was
    // thrown" — a stale/disconnected reader could still report PASS by
    // that weaker bar alone.
    var elapsed = 0.0
    let pollInterval = 0.5
    while elapsed < durationSeconds {
        Thread.sleep(forTimeInterval: pollInterval)
        elapsed += pollInterval
        print("  [t=\(String(format: "%.1f", elapsed))s] local ring buffer framesAvailable=\(ringBuffer.framesAvailable)")
    }
    output.stop()
    capture.stop()
    print("\nPASS: ran the full virtual-device capture -> local-output path with no error.")
    print("Human check still needed: did you actually hear audio that was sent to the SoundCast device?")
    exit(0)
} catch {
    output.stop()
    capture.stop()
    print("\nFAIL: \(error)")
    if case VirtualDeviceCapture.CaptureError.shmOpenFailed = error {
        print("shm_open failed — has the SoundCast.driver's StartIO ever run (i.e. has anything used it as an output device at least once since the last coreaudiod restart)?")
    }
    exit(1)
}
