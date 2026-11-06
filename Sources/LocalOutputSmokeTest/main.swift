import AudioToolbox
import CoreAudio
import Foundation
import SoundCastCore

// Autonomous smoke test for LocalOutputEngine (design doc §3) — the half
// of Phase 1 that needs NO privacy consent (only *capturing* system
// audio does; *rendering* a synthetic tone to an output device is
// unprivileged). Feeds a 440Hz sine tone into the same RingBuffer/
// LocalOutputEngine machinery the real app uses, pointed at whichever
// local output devices are passed as arguments (device UIDs) or, with
// no arguments, every enumerated "This Mac"/"Bluetooth" device.
//
// Usage:
//   LocalOutputSmokeTest                  # test every local device found
//   LocalOutputSmokeTest <uid> [<uid>...] # test specific device(s)
//
// Exit code 0 + "PASS" means the aggregate device, IOProc, and gain
// fan-out all ran without a Core Audio error for the requested duration.
// It does NOT confirm audio was actually audible (no microphone here to
// verify that) — only that the API calls this shares with the real app
// succeeded. A human still needs to confirm they heard the tone.

/// All the test's mutable state lives here, not at file (top-level)
/// scope — top-level `var`s in a Swift 6 executable are implicitly
/// main-actor-isolated, which a background producer thread mutating
/// them directly would violate (the compiler warned on exactly this in
/// an earlier version of this file). An explicit `@unchecked Sendable`
/// box is a reasonable, honest opt-out here: this is a single-producer,
/// single-field mutation with no real concurrency hazard (only the
/// producer thread ever touches `phase`), just not a shape the strict
/// concurrency checker can prove safe on its own.
final class ToneGenerator: @unchecked Sendable {
    private let ringBuffer: RingBuffer
    private let phaseIncrement: Double
    private var phase = 0.0
    private let stopSignal = DispatchSemaphore(value: 0)

    init(ringBuffer: RingBuffer, frequency: Double, sampleRate: Double) {
        self.ringBuffer = ringBuffer
        self.phaseIncrement = 2.0 * Double.pi * frequency / sampleRate
    }

    func start() {
        let queue = DispatchQueue(label: "com.soundcast.smoketest.producer")
        queue.async { [self] in
            let chunkFrames = 480 // 10ms at 48kHz
            var chunk = [Float](repeating: 0, count: chunkFrames * 2)
            while self.stopSignal.wait(timeout: .now()) == .timedOut {
                for i in 0..<chunkFrames {
                    // Modest amplitude (0.2) — this plays for real, don't blast it.
                    let sample = Float(sin(self.phase) * 0.2)
                    chunk[i * 2] = sample
                    chunk[i * 2 + 1] = sample
                    self.phase += self.phaseIncrement
                    if self.phase > 2.0 * Double.pi { self.phase -= 2.0 * Double.pi }
                }
                chunk.withUnsafeBufferPointer { ptr in
                    self.ringBuffer.write(ptr.baseAddress!, count: chunkFrames * 2)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    func stop() {
        stopSignal.signal()
    }
}

func runSmokeTest() -> Never {
    CPUFeatureGuard.logAndGuard(context: "LocalOutputSmokeTest launch")

    let allDevices = LocalDeviceEnumerator.listOutputDevices()
    print("Discovered \(allDevices.count) local output device(s):")
    for device in allDevices {
        print("  [\(device.category.rawValue)] \(device.name)  uid=\(device.id)")
    }

    let requestedUIDs = Set(CommandLine.arguments.dropFirst())
    let targetDevices = requestedUIDs.isEmpty
        ? allDevices
        : allDevices.filter { requestedUIDs.contains($0.id) }

    guard !targetDevices.isEmpty else {
        print("No matching devices to test. Exiting.")
        exit(1)
    }

    print("\nTesting with: \(targetDevices.map(\.name).joined(separator: ", "))")

    let ringBuffer = RingBuffer(capacitySamples: 48_000 * 2 * 2)
    let generator = ToneGenerator(ringBuffer: ringBuffer, frequency: 440.0, sampleRate: 48_000.0)
    generator.start()

    let engine = LocalOutputEngine(sourceRingBuffer: ringBuffer)
    engine.masterGain = 1.0
    let targets = targetDevices.map { LocalOutputEngine.Target(device: $0, gain: 1.0) }

    do {
        try engine.reconfigure(targets: targets)
        print("\nAggregate device created and IOProc started successfully.")
        print("Playing 440Hz test tone for 4 seconds — listen for it now if you're at the Mac...")
        Thread.sleep(forTimeInterval: 4.0)
        engine.stop()
        generator.stop()
        print("\nPASS: ran the full local-output path (aggregate device + IOProc + gain fan-out) with no Core Audio error.")
        print("Human check still needed: did you actually hear a tone?")
        exit(0)
    } catch {
        generator.stop()
        print("\nFAIL: \(error)")
        exit(1)
    }
}

runSmokeTest()
