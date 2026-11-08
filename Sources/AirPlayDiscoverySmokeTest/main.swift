import Foundation
import SoundCastCore

final class SonosTestTone: @unchecked Sendable {
    private let buffer: RingBuffer
    private let stopSignal = DispatchSemaphore(value: 0)

    init(buffer: RingBuffer) { self.buffer = buffer }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var phase = 0.0
            var samples = [Float](repeating: 0, count: 960)
            while stopSignal.wait(timeout: .now()) == .timedOut {
                for frame in 0..<480 {
                    let sample = Float(sin(phase) * 0.1)
                    samples[frame * 2] = sample
                    samples[frame * 2 + 1] = sample
                    phase += 2 * Double.pi * 440 / 48_000
                    if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
                }
                samples.withUnsafeBufferPointer { buffer.write($0.baseAddress!, count: $0.count) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    func stop() { stopSignal.signal() }
}

// Bonjour discovery smoke test for AirPlay receivers, Sonos UPnP
// descriptions with --sonos, a local silent WAV endpoint with --sonos-wav,
// or a live capture-to-Sonos run with --sonos-live <name>.
//
// Usage: AirPlayDiscoverySmokeTest [--sonos|--sonos-wav|--sonos-live <name>] [<seconds, default 8>] [<server seconds>]

CPUFeatureGuard.logAndGuard(context: "AirPlayDiscoverySmokeTest launch")

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--capture-level" || args.first == "--capture-level-virtual" {
    let duration = args.dropFirst().first.flatMap(Int.init) ?? 15
    let buffer = RingBuffer(capacitySamples: 48_000 * 2 * 4)
    let capture: any AudioCaptureSource = args.first == "--capture-level-virtual"
        ? VirtualDeviceCapture(ringBuffer: buffer)
        : ProcessTapCapture(ringBuffer: buffer)
    do {
        try capture.start()
        defer { capture.stop() }
        print("Capture active; checking levels for \(duration)s.")
        for _ in 0..<max(0, duration) {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let available = buffer.framesAvailable
            var samples = [Float](repeating: 0, count: available)
            if available > 0 {
                samples.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, count: $0.count) }
            }
            let peak = samples.reduce(Float(0)) { max($0, $1.isFinite ? abs($1) : 0) }
            print("captured samples=\(available) peak=\(peak)")
        }
    } catch {
        print("FAIL: capture level test: \(error)")
        exit(1)
    }
    exit(0)
}
let sonosToneMode = args.first == "--sonos-tone"
let sonosVirtualMode = args.first == "--sonos-virtual"
let sonosLiveMode = args.first == "--sonos-live" || sonosToneMode || sonosVirtualMode
let sonosMode = args.first == "--sonos" || args.first == "--sonos-wav" || sonosLiveMode
let sonosWAVMode = args.first == "--sonos-wav"
if sonosMode { args.removeFirst() }
let sonosTargetName = sonosLiveMode && !args.isEmpty ? args.removeFirst() : nil
let durationSeconds = args.first.flatMap(Double.init) ?? 8.0
let serverDurationSeconds = sonosWAVMode && args.count > 1
    ? (Double(args[1]) ?? durationSeconds)
    : durationSeconds

let pollInterval = 0.5
if sonosMode {
    let discovery = SonosDiscovery()
    await discovery.start()
    print("Browsing _sonos._tcp and fetching device descriptions for \(durationSeconds)s...")

    var elapsed = 0.0
    var discovered: [String: SonosReceiver] = [:]
    var transportQueries = 0
    var liveTargetFound = false
    while elapsed < durationSeconds {
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        elapsed += pollInterval
        for receiver in await discovery.receivers where discovered[receiver.id] == nil {
            discovered[receiver.id] = receiver
            if sonosLiveMode && receiver.name == sonosTargetName { liveTargetFound = true }
            let modelText = receiver.model.map { " (\($0))" } ?? ""
            print("    - \(receiver.name)\(modelText) id=\(receiver.id) location=\(receiver.descriptionURL)")
            if !sonosWAVMode {
                do {
                    let info = try await SonosUPnPClient.getTransportInfo(for: receiver)
                    transportQueries += 1
                    print("      transport state=\(info.currentTransportState) status=\(info.currentTransportStatus) speed=\(info.currentSpeed)")
                } catch {
                    print("      GetTransportInfo failed: \(error)")
                }
            }
        }
        if liveTargetFound { break }
    }

    await discovery.stop()
    if discovered.isEmpty {
        print("\nFAIL: discovered zero Sonos receivers with readable UPnP descriptions.")
        exit(1)
    }
    if sonosLiveMode {
        guard let sonosTargetName,
              let receiver = discovered.values.first(where: { $0.name == sonosTargetName }) else {
            print("\nFAIL: Sonos receiver \(sonosTargetName ?? "<missing name>") was not discovered.")
            exit(1)
        }
        let captureBuffer = RingBuffer(capacitySamples: 48_000 * 2 * 4)
        let capture: (any AudioCaptureSource)?
        if sonosToneMode {
            capture = nil
        } else if sonosVirtualMode {
            capture = VirtualDeviceCapture(ringBuffer: captureBuffer)
        } else {
            capture = ProcessTapCapture(ringBuffer: captureBuffer)
        }
        let tone = sonosToneMode ? SonosTestTone(buffer: captureBuffer) : nil
        do {
            try capture?.start()
            tone?.start()
            let streamer = SonosAudioStreamer(
                receiver: receiver, source: captureBuffer, sampleRate: capture?.sampleRate ?? 48_000
            )
            do {
                try await streamer.start()
                print("Sonos stream started for \(durationSeconds)s. \(sonosToneMode ? "Playing test tone." : "Now open the audio source on this Mac.")")
                try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
                await streamer.stop()
                tone?.stop()
                capture?.stop()
                print("PASS: Sonos stream stopped cleanly.")
            } catch {
                await streamer.stop()
                tone?.stop()
                capture?.stop()
                throw error
            }
        } catch {
            print("\nFAIL: Sonos live stream failed: \(error)")
            exit(1)
        }
        exit(0)
    }
    if sonosWAVMode {
        guard let receiver = discovered.values.sorted(by: { $0.id < $1.id }).first,
              let peerIPv4 = receiver.descriptionURL.host else {
            print("\nFAIL: no Sonos receiver has a usable IPv4 address.")
            exit(1)
        }
        let silence = RingBuffer(capacitySamples: 48_000 * 2 * 2)
        let server = SonosHTTPAudioServer(source: silence, sampleRate: 48_000)
        do {
            let url = try await server.start(peerIPv4: peerIPv4)
            defer { server.stop() }
            print("Serving silent WAV test stream at \(url) for \(serverDurationSeconds)s; no Sonos playback command will be sent.")
            try await Task.sleep(nanoseconds: UInt64(serverDurationSeconds * 1_000_000_000))
            print("PASS: silent WAV HTTP server started and stopped cleanly.")
        } catch {
            print("\nFAIL: could not start Sonos WAV test server: \(error)")
            exit(1)
        }
        exit(0)
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
