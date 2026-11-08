import Foundation
import SoundCastCore

enum SonosReconnectError: Error, CustomStringConvertible {
    case noClients
    case notPlaying(String, String)
    case notStopped(String, String)
    case notPaused(String, String)

    var description: String {
        switch self {
        case .noClients: return "no media connection was available to interrupt"
        case .notPlaying(let state, let status): return "transport did not resume: \(state)/\(status)"
        case .notStopped(let state, let status): return "transport did not stay stopped: \(state)/\(status)"
        case .notPaused(let state, let status): return "transport did not stay paused: \(state)/\(status)"
        }
    }
}

final class SonosTestTone: @unchecked Sendable {
    private let buffer: RingBuffer
    private let amplitude: Float
    private let stopSignal = DispatchSemaphore(value: 0)

    init(buffer: RingBuffer, amplitude: Float = 0.1) {
        self.buffer = buffer
        self.amplitude = amplitude
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var phase = 0.0
            var samples = [Float](repeating: 0, count: 960)
            while stopSignal.wait(timeout: .now()) == .timedOut {
                for frame in 0..<480 {
                    let sample = Float(sin(phase)) * amplitude
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
if args.first == "--sonos-server-start-probe" {
    let server = SonosHTTPAudioServer(source: RingBuffer(capacitySamples: 96_000), sampleRate: 48_000)
    do {
        for _ in 0..<2 {
            do {
                _ = try server.start(peerIPv4: "invalid")
                server.stop()
                print("FAIL: accepted an invalid receiver address.")
                exit(1)
            } catch SonosHTTPAudioServer.ServerError.invalidPeerAddress {
            }
        }
        let url = try server.start(peerIPv4: "127.0.0.1")
        defer { server.stop() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type") == "audio/wav",
              http.value(forHTTPHeaderField: "Content-Length") == "2147483644" else {
            print("FAIL: listener returned an unexpected HTTP response.")
            exit(1)
        }
        print("PASS: listener recovered from failed starts and served a WAV response.")
    } catch {
        print("FAIL: listener startup probe: \(error)")
        exit(1)
    }
    exit(0)
}
if args.first == "--sonos-invalid-rate" {
    let receiver = SonosReceiver(
        id: "test", name: "test", model: nil,
        descriptionURL: URL(string: "http://127.0.0.1/")!, avTransportControlURL: nil
    )
    for rate in [Double.nan, Double.infinity, -1, 0, 7_999, 192_001] {
        let streamer = SonosAudioStreamer(receiver: receiver, source: RingBuffer(capacitySamples: 2), sampleRate: rate)
        for _ in 0..<2 {
            do {
                try await streamer.start()
                await streamer.stop()
                print("FAIL: accepted invalid sample rate \(rate)")
                exit(1)
            } catch SonosHTTPAudioServer.ServerError.invalidSampleRate {
            } catch {
                print("FAIL: unexpected error for sample rate \(rate): \(error)")
                exit(1)
            }
        }
    }
    print("PASS: invalid sample rates rejected without starting or retaining a session.")
    exit(0)
}
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
let sonosManualRetryMode = args.first == "--sonos-retry-probe" || args.first == "--sonos-long-outage-retry-probe"
let sonosLongOutageStopProbe = args.first == "--sonos-long-outage-stop-probe"
let sonosStopProbe = args.first == "--sonos-stop-probe" || sonosLongOutageStopProbe
let sonosSwitchProbe = args.first == "--sonos-switch-probe"
let sonosExternalStopProbe = args.first == "--sonos-external-stop-probe"
let sonosExternalPauseProbe = args.first == "--sonos-external-pause-probe"
let sonosLongOutageProbe = args.first == "--sonos-long-outage-probe" || args.first == "--sonos-long-outage-retry-probe" || sonosLongOutageStopProbe
let sonosSilentReconnectMode = args.first == "--sonos-reconnect-silent" || sonosStopProbe || sonosSwitchProbe || sonosExternalStopProbe || sonosExternalPauseProbe || sonosLongOutageProbe
let sonosReconnectMode = args.first == "--sonos-reconnect" || sonosManualRetryMode || sonosSilentReconnectMode
let sonosSustainProbe = args.first == "--sonos-sustain-silent"
let sonosToneMode = args.first == "--sonos-tone" || sonosReconnectMode || sonosSustainProbe
let dualCastMode = args.first == "--dual-cast"
let sonosVirtualMode = args.first == "--sonos-virtual" || dualCastMode
let sonosLiveMode = args.first == "--sonos-live" || sonosToneMode || sonosVirtualMode
let sonosMode = args.first == "--sonos" || args.first == "--sonos-wav" || sonosLiveMode
let sonosWAVMode = args.first == "--sonos-wav"
if sonosMode { args.removeFirst() }
let airplayTargetName = dualCastMode && !args.isEmpty ? args.removeFirst() : nil
let sonosTargetName = sonosLiveMode && !args.isEmpty ? args.removeFirst() : nil
let durationSeconds = args.first.flatMap(Double.init) ?? 8.0
let sonosDelaySeconds = dualCastMode && args.count > 1 ? (Double(args[1]) ?? 0) : 0
let outageSeconds = sonosLongOutageProbe && args.count > 1 ? Int(args[1]) : 8
if sonosLongOutageProbe && (outageSeconds == nil || !(1...30).contains(outageSeconds!)) {
    print("FAIL: outage duration must be an integer from 1 to 30 seconds.")
    exit(1)
}
let observationSeconds = sonosLongOutageProbe ? max(25, outageSeconds! + 20) : 15
let minimumReconnectDuration = 10 + observationSeconds
if sonosReconnectMode && (!durationSeconds.isFinite || durationSeconds < Double(minimumReconnectDuration)) {
    print("FAIL: reconnect probes require at least \(minimumReconnectDuration) seconds.")
    exit(1)
}
if sonosSustainProbe && (!durationSeconds.isFinite || durationSeconds < 30) {
    print("FAIL: --sonos-sustain-silent requires at least 30 seconds.")
    exit(1)
}
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
        let tone = sonosToneMode ? SonosTestTone(buffer: captureBuffer, amplitude: sonosSilentReconnectMode || sonosSustainProbe ? 0 : 0.1) : nil
        var airplaySender: AirPlayRealtimeSender?
        var airplayClock: AirPlayPTPClock?
        do {
            try capture?.start()
            tone?.start()
            if dualCastMode {
                guard let airplayTargetName else {
                    throw NSError(domain: "DualCast", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing AirPlay receiver name"])
                }
                let airplayReceiver = try await AirPlayReceiverResolver.resolve(serviceName: airplayTargetName)
                let clock = try AirPlayPTPClock(peerIPv4: airplayReceiver.ipv4)
                airplayClock = clock
                clock.start()
                let sender = AirPlayRealtimeSender(
                    receiver: airplayReceiver, identity: AirPlayIdentity.loadOrCreate(), ptpClock: clock,
                    source: captureBuffer, inputSampleRate: capture?.sampleRate ?? 48_000
                )
                airplaySender = sender
                sender.onFailure = { error in NSLog("[SoundCast][DualCast] AirPlay failed: \(error)") }
                try await sender.start()
                print("AirPlay stream started for \(airplayTargetName).")
            }
            let streamer = SonosAudioStreamer(
                receiver: receiver, source: captureBuffer, sampleRate: capture?.sampleRate ?? 48_000,
                delaySeconds: sonosDelaySeconds
            )
            do {
                try await streamer.start()
                print("Sonos stream started for \(durationSeconds)s. \(sonosSilentReconnectMode || sonosSustainProbe ? "Playing silence." : sonosToneMode ? "Playing test tone." : "Now open the audio source on this Mac.")")
                if sonosSustainProbe {
                    var remaining = durationSeconds
                    while remaining > 0 {
                        let interval = min(30, remaining)
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                        remaining -= interval
                        let info = try await SonosUPnPClient.getTransportInfo(for: receiver)
                        print("Transport at \(durationSeconds - remaining)s: \(info.currentTransportState)/\(info.currentTransportStatus)")
                        guard info.currentTransportState == "PLAYING", info.currentTransportStatus == "OK" else {
                            throw SonosReconnectError.notPlaying(info.currentTransportState, info.currentTransportStatus)
                        }
                    }
                } else if sonosReconnectMode {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    if sonosExternalStopProbe || sonosExternalPauseProbe {
                        if sonosExternalPauseProbe {
                            try await SonosUPnPClient.pause(receiver)
                            print("Sent an external Pause action.")
                        } else {
                            try await SonosUPnPClient.stop(receiver)
                            print("Sent an external Stop action.")
                        }
                        try await Task.sleep(nanoseconds: 6_000_000_000)
                        let info = try await SonosUPnPClient.getTransportInfo(for: receiver)
                        print("Transport after external action: \(info.currentTransportState)/\(info.currentTransportStatus)")
                        if sonosExternalPauseProbe {
                            guard info.currentTransportState == "PAUSED_PLAYBACK" else {
                                throw SonosReconnectError.notPaused(info.currentTransportState, info.currentTransportStatus)
                            }
                        } else {
                            guard info.currentTransportState == "PLAYING" else {
                                throw SonosReconnectError.notPlaying(info.currentTransportState, info.currentTransportStatus)
                            }
                        }
                        await streamer.stop()
                        tone?.stop()
                        print(sonosExternalPauseProbe ? "PASS: external pause remained paused." : "PASS: external stop was automatically restarted.")
                        exit(0)
                    }
                    let disconnected = streamer.disconnectClientsForTesting(unavailableSeconds: sonosLongOutageProbe ? Double(outageSeconds!) : 0)
                    print("Forced media disconnect for \(disconnected) client(s).\(sonosLongOutageProbe ? " Rejecting receiver requests for \(outageSeconds!) seconds." : "")")
                    guard disconnected > 0 else { throw SonosReconnectError.noClients }
                    if sonosSwitchProbe {
                        guard let peerIPv4 = receiver.descriptionURL.host else {
                            throw NSError(domain: "SonosSwitchProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing speaker address"])
                        }
                        let silence = RingBuffer(capacitySamples: 48_000 * 4)
                        let alternateServer = SonosHTTPAudioServer(source: silence, sampleRate: 48_000)
                        let alternateURI = try alternateServer.start(peerIPv4: peerIPv4)
                        defer { alternateServer.stop() }
                        do {
                            try await SonosUPnPClient.setAVTransportURI(for: receiver, uri: alternateURI)
                            try await Task.sleep(nanoseconds: 6_000_000_000)
                            var info = try await SonosUPnPClient.getTransportInfo(for: receiver)
                            if info.currentTransportState != "PLAYING" {
                                try await SonosUPnPClient.play(receiver)
                            }
                            await streamer.stop()
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            let uri = try await SonosUPnPClient.getCurrentURI(for: receiver)
                            info = try await SonosUPnPClient.getTransportInfo(for: receiver)
                            print("Transport after source change and stop: \(info.currentTransportState)/\(info.currentTransportStatus), URI=\(uri)")
                            guard uri == alternateURI.absoluteString, info.currentTransportState == "PLAYING" else {
                                throw SonosReconnectError.notPlaying(info.currentTransportState, info.currentTransportStatus)
                            }
                            try await SonosUPnPClient.stop(receiver)
                        } catch {
                            try? await SonosUPnPClient.stop(receiver)
                            throw error
                        }
                        tone?.stop()
                        print("PASS: recovery and stop left the new source playing.")
                        exit(0)
                    }
                    if sonosStopProbe {
                        try await Task.sleep(nanoseconds: sonosLongOutageStopProbe ? 10_000_000_000 : 200_000_000)
                        await streamer.stop()
                        tone?.stop()
                        try await Task.sleep(nanoseconds: sonosLongOutageStopProbe ? 20_000_000_000 : 6_000_000_000)
                        let info = try await SonosUPnPClient.getTransportInfo(for: receiver)
                        print("Transport after stop: \(info.currentTransportState)/\(info.currentTransportStatus)")
                        guard info.currentTransportState == "STOPPED" else {
                            throw SonosReconnectError.notStopped(info.currentTransportState, info.currentTransportStatus)
                        }
                        print("PASS: stopped playback did not resume.")
                        exit(0)
                    }
                    try await Task.sleep(nanoseconds: UInt64(observationSeconds) * 1_000_000_000)
                    let info = try await SonosUPnPClient.getTransportInfo(for: receiver)
                    print("Transport after disconnect: \(info.currentTransportState)/\(info.currentTransportStatus)")
                    var recovered = info
                    if sonosManualRetryMode && info.currentTransportState == "STOPPED" {
                        print("Retrying Play after disconnect.")
                        try await SonosUPnPClient.play(receiver)
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        recovered = try await SonosUPnPClient.getTransportInfo(for: receiver)
                        print("Transport after retry: \(recovered.currentTransportState)/\(recovered.currentTransportStatus)")
                    }
                    guard recovered.currentTransportState == "PLAYING", recovered.currentTransportStatus == "OK" else {
                        throw SonosReconnectError.notPlaying(recovered.currentTransportState, recovered.currentTransportStatus)
                    }
                    let elapsedSeconds = 10 + Double(observationSeconds)
                    if durationSeconds > elapsedSeconds {
                        try await Task.sleep(nanoseconds: UInt64((durationSeconds - elapsedSeconds) * 1_000_000_000))
                    }
                } else {
                    try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
                }
                await streamer.stop()
                await airplaySender?.stop()
                airplayClock?.stop()
                tone?.stop()
                capture?.stop()
                print("PASS: Sonos stream stopped cleanly.")
            } catch {
                await streamer.stop()
                throw error
            }
        } catch {
            await airplaySender?.stop()
            airplayClock?.stop()
            tone?.stop()
            capture?.stop()
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
