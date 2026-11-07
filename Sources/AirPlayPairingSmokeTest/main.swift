import Foundation
import Network
import SoundCastCore

// Design doc §12 Phase 2 step 2 smoke test: exercises the real
// AirPlayRTSPConnection/TLV8/ChaCha20-Poly1305 wire protocol against a
// real AirPlay 2 receiver.
//
// Usage:
//   AirPlayPairingSmokeTest verify <ipv6-link-local-address> <interface-name> [port]
//   AirPlayPairingSmokeTest setup <ipv6-link-local-address> <interface-name> <pin> [port]
//   AirPlayPairingSmokeTest realtime-setup <ipv6-link-local-address> <interface-name> <receiver-ipv4> [port] [audio-seconds]

CPUFeatureGuard.logAndGuard(context: "AirPlayPairingSmokeTest launch")

let args = Array(CommandLine.arguments.dropFirst())

// `cast <bonjour-name> [seconds]`: exercises the production
// AirPlayRealtimeSender exactly as the app uses it — Bonjour resolve,
// shared PTP clock, a ring buffer fed like a 48 kHz capture callback
// (so the 48k → 44.1k resampling path runs), wall-clock pacing, volume
// change mid-stream, and TEARDOWN. Plays 440 Hz, then 660 Hz at half
// volume for the second half.
if args.first == "cast" {
    guard args.count >= 2 else {
        print("Usage: AirPlayPairingSmokeTest cast <bonjour-name> [seconds]")
        exit(1)
    }
    let seconds = args.count >= 3 ? (Double(args[2]) ?? 10) : 10
    let identity = AirPlayIdentity.loadOrCreate()
    do {
        print("Resolving \"\(args[1])\"...")
        let receiver = try await AirPlayReceiverResolver.resolve(serviceName: args[1])
        print("Resolved: \(receiver)")
        let clock = try AirPlayPTPClock(peerIPv4: receiver.ipv4)
        clock.start()
        defer { clock.stop() }

        let captureRate = 48_000.0
        let ring = RingBuffer(capacitySamples: Int(captureRate) * 2 * 2)
        let producerRunning = ManagedAtomicFlag()
        producerRunning.set(true)
        let halfway = Date().addingTimeInterval(seconds / 2 + 2)
        let producer = Thread {
            var phase: Float = 0
            let chunk = 512
            var samples = [Float](repeating: 0, count: chunk * 2)
            let start = DispatchTime.now().uptimeNanoseconds
            var produced = 0
            while producerRunning.get() {
                let frequency: Float = Date() < halfway ? 440 : 660
                for frame in 0..<chunk {
                    let value = sin(phase) * 0.3
                    samples[frame * 2] = value
                    samples[frame * 2 + 1] = value
                    phase += 2 * .pi * frequency / Float(captureRate)
                    if phase > 2 * .pi { phase -= 2 * .pi }
                }
                samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
                produced += chunk
                let deadline = start + UInt64(Double(produced) / captureRate * 1e9)
                let now = DispatchTime.now().uptimeNanoseconds
                if deadline > now { usleep(useconds_t((deadline - now) / 1000)) }
            }
        }
        producer.start()

        let sender = AirPlayRealtimeSender(
            receiver: receiver, identity: identity, ptpClock: clock,
            source: ring, inputSampleRate: captureRate
        )
        sender.onFailure = { error in print("Sender failed: \(error)") }
        print("Starting sender...")
        try await sender.start()
        print("Streaming for \(seconds) s (audible after ~2 s latency)...")
        try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
        print("Halfway: switching to 660 Hz and setting volume 0.5.")
        sender.setVolume(0.5)
        try await Task.sleep(nanoseconds: UInt64((seconds / 2 + 2) * 1e9))
        print("Stopping (TEARDOWN)...")
        await sender.stop()
        producerRunning.set(false)
        print("PASS: sender started, streamed, and stopped cleanly.")
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
    exit(0)
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
    func get() -> Bool { lock.withLock { value } }
}

guard args.count >= 3 else {
    print("Usage:")
    print("  AirPlayPairingSmokeTest verify <ipv6-link-local-address> <interface-name> [port]")
    print("  AirPlayPairingSmokeTest setup <ipv6-link-local-address> <interface-name> <pin> [port]")
    exit(1)
}
let mode = args[0]
let address = args[1]
let interfaceName = args[2]

let identity = AirPlayIdentity.loadOrCreate()
print("Using SoundCast identity pairingID=\(identity.pairingID)")

func connect(port: UInt16) async throws -> AirPlayRTSPConnection {
    let host = NWEndpoint.Host("\(address)%\(interfaceName)")
    let connection = AirPlayRTSPConnection(host: host, port: NWEndpoint.Port(rawValue: port)!)
    print("Connecting to [\(address)%\(interfaceName)]:\(port)...")
    try await connection.connect()
    print("Connected.")
    return connection
}

switch mode {
case "verify":
    let port = args.count >= 4 ? (UInt16(args[3]) ?? 7000) : 7000
    let connection = try await connect(port: port)
    do {
        print("Running pair-verify (succeeds if this identity has completed pair-setup against this device before; otherwise expect a clean TLV8 rejection)...")
        let keys = try await AirPlayPairVerify.run(connection: connection, identity: identity)
        print("Pair-verify completed, got session keys (readKey/writeKey present: \(keys.readKey.withUnsafeBytes { !$0.isEmpty }), \(keys.writeKey.withUnsafeBytes { !$0.isEmpty }))")
        print("Enabling encrypted channel and sending GET /info through it...")
        connection.enableEncryption(readKey: keys.readKey, writeKey: keys.writeKey)
        let infoResponse = try await connection.send(method: "GET", path: "/info", extraHeaders: ["X-Apple-ProtocolVersion": "1"])
        print("Encrypted GET /info -> status \(infoResponse.statusCode), body \(infoResponse.body.count) bytes")
        print("\nPASS: this device trusts SoundCast's identity, a real encrypted session is established, and the encrypted framing itself decoded a real response.")
    } catch AirPlayPairVerify.PairVerifyError.rejected(let errorCode) {
        print("\nPASS: real device cleanly rejected pair-verify with TLV8 Error=\(errorCode) (expected if this identity hasn't run pair-setup against this device yet). The wire protocol itself worked end-to-end.")
    } catch {
        print("\nFAIL: \(error)")
        connection.close()
        exit(1)
    }
    connection.close()

case "setup":
    // Two steps, same connection kept open throughout: trigger the PIN
    // (confirmed live — closing the connection right after suppresses
    // the PIN with no error), then poll a drop-file for the PIN once a
    // human has read it off the real device's screen (file-based, not
    // interactive stdin, since this runs orchestrated over SSH rather
    // than an attached terminal), then complete the SRP exchange.
    let port = args.count >= 4 ? (UInt16(args[3]) ?? 7000) : 7000
    let pinFilePath = args.count >= 5 ? args[4] : "/tmp/soundcast_pin.txt"
    try? FileManager.default.removeItem(atPath: pinFilePath)
    let connection = try await connect(port: port)
    do {
        print("Triggering pair-pin-start — check the device's screen now...")
        try await AirPlayPairSetup.startPinFlow(connection: connection)
        print("Waiting for PIN to be written to \(pinFilePath) (up to 90s)...")
        var pin: String?
        for _ in 0..<90 {
            if let contents = try? String(contentsOfFile: pinFilePath, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pin = trimmed
                    break
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let pin else {
            print("Timed out waiting for PIN.")
            connection.close()
            exit(1)
        }
        print("Completing pair-setup with PIN \"\(pin)\"...")
        try await AirPlayPairSetup.completeSetup(connection: connection, identity: identity, setupCode: pin, transient: false)
        print("\nPASS: pair-setup completed successfully (LTPK exchange verified).")
    } catch {
        print("\nFAIL: \(error)")
        connection.close()
        exit(1)
    }
    connection.close()

case "stream":
    let port = args.count >= 4 ? (UInt16(args[3]) ?? 7000) : 7000
    let connection = try await connect(port: port)
    do {
        print("Running pair-verify...")
        let keys = try await AirPlayPairVerify.run(connection: connection, identity: identity)
        connection.enableEncryption(readKey: keys.readKey, writeKey: keys.writeKey)
        let sessionUUID = UUID().uuidString
        // IPv6 literal in a URI authority needs bracket notation, or the
        // address's own colons are ambiguous with the URI's port syntax.
        let requestTarget = "rtsp://[\(address)]/\(sessionUUID)"
        print("Encrypted channel up. Trying OPTIONS first...")
        let optionsResponse = try await connection.send(method: "OPTIONS", path: requestTarget)
        print("OPTIONS -> status \(optionsResponse.statusCode), headers \(optionsResponse.headers)")
        print("Running RTSP SETUP...")
        let sharedKey = keys.audioKey.withUnsafeBytes { Array($0) }
        let host = NWEndpoint.Host("\(address)%\(interfaceName)")
        let setupResult = try await AirPlayStreamSetup.run(
            connection: connection, host: host, requestTarget: requestTarget, sessionUUID: sessionUUID, sharedKey: sharedKey
        )
        print("SETUP ok (event connection open): dataPort=\(setupResult.dataPort) controlPort=\(setupResult.controlPort)")
        print("Running RECORD...")
        try await AirPlayStreamSetup.record(connection: connection, requestTarget: requestTarget)
        print("\nPASS: SETUP + RECORD both succeeded.")
        setupResult.eventConnection.close()
    } catch AirPlayStreamSetup.StreamError.unexpectedStatus(let code, let body) {
        print("\nFAIL: unexpected status \(code), body (\(body.count) bytes): \(String(data: Data(body), encoding: .utf8) ?? body.map { String(format: "%02x", $0) }.joined())")
        connection.close()
        exit(1)
    } catch {
        print("\nFAIL: \(error)")
        connection.close()
        exit(1)
    }
    connection.close()

case "realtime-setup":
    guard args.count >= 4 else {
        print("Usage: AirPlayPairingSmokeTest realtime-setup <ipv6-link-local-address> <interface-name> <receiver-ipv4> [port] [seconds] [ptp|ntp]")
        exit(1)
    }
    let receiverIPv4 = args[3]
    let port = args.count >= 5 ? (UInt16(args[4]) ?? 7000) : 7000
    let audioDuration = args.count >= 6 ? (Double(args[5]) ?? 0) : 0
    let useNTP = args.count >= 7 && args[6].lowercased() == "ntp"
    let ptpClock: AirPlayPTPClock? = useNTP ? nil : try AirPlayPTPClock(peerIPv4: receiverIPv4)
    let ntpTiming: AirPlayNTPTiming? = useNTP ? try AirPlayNTPTiming(peerIPv4: receiverIPv4) : nil
    defer { ptpClock?.stop(); ntpTiming?.stop() }
    ptpClock?.start()
    ntpTiming?.start()
    let localIPv4 = ptpClock?.localAddress ?? ntpTiming!.localAddress
    // RTP audio/control must go to the same (IPv6) address as RTSP: the
    // receiver binds the stream ports there and rejects IPv4 with ICMP.
    let streamAddress = "\(address)%\(interfaceName)"
    let controlSocket = try AirPlayUDPPort(localAddress: localIPv4)
    let dataSocket = try AirPlayUDPPort(localAddress: localIPv4)
    /// Sync packet for the control channel; `next` is the next RTP
    /// timestamp to send, which plays 2 s (88200 frames) after "now".
    func syncPacket(next: UInt32, first: Bool) -> [UInt8] {
        if let ntpTiming {
            return ntpTiming.syncPacket(currentPosition: next &- 88_200, nextTimestamp: next, first: first)
        }
        return ptpClock!.realtimeSyncPacket(rtpTimestamp: next, first: first)
    }
    let connection = try await connect(port: port)
    do {
        print("Running pair-verify...")
        let keys = try await AirPlayPairVerify.run(connection: connection, identity: identity)
        connection.enableEncryption(readKey: keys.readKey, writeKey: keys.writeKey)
        let sessionUUID = UUID().uuidString
        let streamConnectionID = Int.random(in: 1...Int(UInt32.max))
        let requestTarget = "rtsp://[\(address)]/\(streamConnectionID)"
        let host = NWEndpoint.Host("\(address)%\(interfaceName)")
        let audioKey = keys.audioKey.withUnsafeBytes { Array($0) }
        let infoResponse = try await connection.send(
            method: "GET",
            path: "/info",
            extraHeaders: ["X-Apple-ProtocolVersion": "1"]
        )
        guard infoResponse.statusCode == 200 else {
            throw AirPlayStreamSetup.StreamError.unexpectedStatus(infoResponse.statusCode, infoResponse.body)
        }
        print("Negotiating realtime type=96 with \(useNTP ? "NTP timing on UDP \(ntpTiming!.port)" : "the local PTP clock")...")
        let setupResult = try await AirPlayStreamSetup.run(
            connection: connection,
            host: host,
            requestTarget: requestTarget,
            sessionUUID: sessionUUID,
            sharedKey: audioKey,
            samplesPerFrame: 352,
            timingProtocol: useNTP ? "NTP" : "PTP",
            timingPort: ntpTiming?.port,
            ptpClock: ptpClock,
            streamType: 96,
            localControlPort: controlSocket.port,
            localDataPort: dataSocket.port,
            streamConnectionID: streamConnectionID,
            recordBeforeStream: true,
            timingPeers: useNTP ? nil : [receiverIPv4, localIPv4],
            deviceID: ntpTiming?.deviceID
        )
        if !useNTP { print("SETPEERS [\(receiverIPv4), \(localIPv4)] accepted.") }
        print("Realtime SETUP accepted: localDataPort=\(dataSocket.port) remoteDataPort=\(setupResult.dataPort) controlPort=\(setupResult.controlPort)")
        let volumeResponse = try await connection.send(
            method: "SET_PARAMETER",
            path: requestTarget,
            extraHeaders: AirPlayStreamSetup.streamHeaders.merging(["Content-Type": "text/parameters"]) { _, new in new },
            body: Array("volume: 0.000000\r\n".utf8)
        )
        print("SET_PARAMETER volume -> status \(volumeResponse.statusCode)")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        if let probes = ptpClock?.probeCounts() {
            print("PTP requests: Delay_Req=\(probes.delayRequests) Pdelay_Req=\(probes.peerDelayRequests) Signaling=\(probes.signalingRequests)")
        }
        if let ntpTiming {
            print("NTP timing requests answered: \(ntpTiming.requestCount)")
        }
        if audioDuration > 0 {
            let sampleRate = 44_100.0
            let encoder = try ALACEncoder(
                inputSampleRate: sampleRate,
                outputSampleRate: sampleRate,
                framesPerPacket: 352
            )
            let stream = AirPlayRealtimeAudioStream(
                udpPort: dataSocket,
                receiverIPv4: streamAddress,
                receiverPort: UInt16(setupResult.dataPort),
                audioKey: audioKey,
                initialSequence: UInt16.random(in: 0...UInt16.max)
            )
            let ntpEpochOffset = 2_208_988_800.0
            let startTime = Date().timeIntervalSince1970 + ntpEpochOffset + 2.0
            var sampleTimestamp = UInt32(truncatingIfNeeded: Int64(startTime * sampleRate))
            try controlSocket.send(
                syncPacket(next: sampleTimestamp, first: true),
                to: streamAddress,
                port: UInt16(setupResult.controlPort)
            )
            let packetCount = Int(audioDuration * sampleRate / 352.0)
            // Pace against absolute deadlines so sleep overhead doesn't
            // accumulate and push the send point behind the anchor.
            let pacingStart = DispatchTime.now().uptimeNanoseconds
            var phase: Float = 0
            let phaseStep = 2 * Float.pi * 440 / Float(sampleRate)
            for packetIndex in 0..<packetCount {
                var samples = [Float](repeating: 0, count: 352 * 2)
                for frame in 0..<352 {
                    let value = sin(phase) * 0.3
                    samples[frame * 2] = value
                    samples[frame * 2 + 1] = value
                    phase += phaseStep
                    if phase >= 2 * Float.pi { phase -= 2 * Float.pi }
                }
                guard let encoded = try encoder.encode(interleavedSamples: samples).first else {
                    throw ALACEncoder.EncoderError.conversionFailed("no 352-frame ALAC packet produced")
                }
                try stream.sendFrame(encoded, timestamp: sampleTimestamp, isFirst: packetIndex == 0)
                sampleTimestamp &+= 352
                if packetIndex > 0 && packetIndex % 100 == 0 {
                    try controlSocket.send(
                        syncPacket(next: sampleTimestamp, first: false),
                        to: streamAddress,
                        port: UInt16(setupResult.controlPort)
                    )
                }
                if packetIndex == 0 {
                    print("Sent first realtime ALAC/RTP packet (\(encoded.count) encoded bytes).")
                }
                let deadline = pacingStart + UInt64(Double(packetIndex + 1) * 352.0 / sampleRate * 1_000_000_000)
                let now = DispatchTime.now().uptimeNanoseconds
                if deadline > now {
                    try await Task.sleep(nanoseconds: deadline - now)
                }
            }
            print("Sent \(packetCount) realtime audio packet(s).")
            if let ntpTiming {
                print("NTP timing requests answered (total): \(ntpTiming.requestCount)")
            }
        }
        setupResult.eventConnection.close()
    } catch AirPlayStreamSetup.StreamError.unexpectedStatus(let code, let body) {
        print("\nFAIL: unexpected status \(code), body (\(body.count) bytes): \(String(data: Data(body), encoding: .utf8) ?? body.map { String(format: "%02x", $0) }.joined())")
        connection.close()
        exit(1)
    } catch {
        print("\nFAIL: \(error)")
        connection.close()
        exit(1)
    }
    connection.close()

case "tone":
    let port = args.count >= 4 ? (UInt16(args[3]) ?? 7000) : 7000
    let durationSeconds = args.count >= 5 ? (Double(args[4]) ?? 5.0) : 5.0
    let nonceStrategy: AirPlayAudioStream.NonceStrategy = {
        guard args.count >= 6 else { return .random }
        switch args[5] {
        case "counterLE": return .counterLE
        case "counterBE": return .counterBE
        default: return .random
        }
    }()
    let aadStrategy: AirPlayAudioStream.AADStrategy = {
        guard args.count >= 7, args[6] == "fullHeader" else { return .timestampSSRC }
        return .fullHeader
    }()
    let connection = try await connect(port: port)
    do {
        print("Running pair-verify...")
        let keys = try await AirPlayPairVerify.run(connection: connection, identity: identity)
        connection.enableEncryption(readKey: keys.readKey, writeKey: keys.writeKey)
        let sessionUUID = UUID().uuidString
        let requestTarget = "rtsp://[\(address)]/\(sessionUUID)"
        _ = try await connection.send(method: "OPTIONS", path: requestTarget)
        let sharedKey = keys.audioKey.withUnsafeBytes { Array($0) }
        let host = NWEndpoint.Host("\(address)%\(interfaceName)")
        print("Running RTSP SETUP...")
        let setupResult = try await AirPlayStreamSetup.run(
            connection: connection, host: host, requestTarget: requestTarget, sessionUUID: sessionUUID, sharedKey: sharedKey
        )
        print("SETUP ok: dataPort=\(setupResult.dataPort)")
        setupResult.eventConnection.startDiagnosticLogging(label: "EVENT")
        print("Opening audio data connection BEFORE RECORD (mirroring the eventPort pattern), with retries...")
        let audioStream = AirPlayAudioStream(host: host, port: NWEndpoint.Port(rawValue: UInt16(setupResult.dataPort))!, sharedKey: sharedKey, nonceStrategy: nonceStrategy, aadStrategy: aadStrategy)
        var connected = false
        for attempt in 1...5 {
            do {
                try await audioStream.connect()
                connected = true
                print("Audio data connection established on attempt \(attempt).")
                break
            } catch {
                print("  attempt \(attempt) failed: \(error) — retrying in 0.3s")
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        guard connected else {
            print("\nFAIL: could not connect to dataPort after 5 attempts.")
            connection.close()
            exit(1)
        }
        print("Running RECORD...")
        try await AirPlayStreamSetup.record(connection: connection, requestTarget: requestTarget)
        print("RECORD ok. Sending SET_PARAMETER (volume)...")
        let volumeBody = Array("volume: 0.000000\r\n".utf8)
        let volResponse = try await connection.send(
            method: "SET_PARAMETER", path: requestTarget,
            extraHeaders: AirPlayStreamSetup.streamHeaders.merging(["Content-Type": "text/parameters"]) { _, n in n },
            body: volumeBody
        )
        print("SET_PARAMETER -> status \(volResponse.statusCode)")
        print("Encoding + streaming a \(durationSeconds)s 440Hz tone...")

        let encoder = try ALACEncoder()
        let inputSampleRate = 48_000.0
        let samplesPerChunk = 1024
        let totalChunks = Int(durationSeconds * inputSampleRate / Double(samplesPerChunk))
        var timestamp: UInt32 = 0
        var phase: Float = 0
        let frequency: Float = 440
        let twoPiFOverSR = 2 * Float.pi * frequency / Float(inputSampleRate)

        for chunkIndex in 0..<totalChunks {
            var samples = [Float](repeating: 0, count: samplesPerChunk * 2)
            for i in 0..<samplesPerChunk {
                let value = sin(phase) * 0.3
                samples[i * 2] = value
                samples[i * 2 + 1] = value
                phase += twoPiFOverSR
                if phase > 2 * Float.pi { phase -= 2 * Float.pi }
            }
            let frames = try encoder.encode(interleavedSamples: samples)
            for frame in frames {
                // AVAudioConverter's very first output frame, seen live,
                // was 6 bytes — an encoder priming artifact, not a real
                // AAC-LC frame (real ones here run ~150-250 bytes).
                // Sending it got the connection reset by the receiver.
                guard frame.count >= 20 else {
                    print("  chunk \(chunkIndex): skipping \(frame.count)-byte priming artifact")
                    continue
                }
                print("  chunk \(chunkIndex): sending frame #\(timestamp / UInt32(encoder.samplesPerFrame)) size=\(frame.count) bytes first8=\(frame.prefix(8).map { String(format: "%02x", $0) }.joined())")
                try await audioStream.sendFrame(audioData: frame, timestamp: timestamp)
                timestamp += UInt32(encoder.samplesPerFrame)
            }
            // ~2s cadence at 1024 samples/48kHz per chunk (~21.3ms each).
            if chunkIndex > 0 && chunkIndex % 94 == 0 {
                _ = try await connection.send(method: "POST", path: "/feedback", extraHeaders: AirPlayStreamSetup.streamHeaders)
            }
            // Pace roughly real-time so we don't flood the TCP buffer.
            try await Task.sleep(nanoseconds: UInt64(Double(samplesPerChunk) / inputSampleRate * 1_000_000_000))
        }
        print("\nPASS: streamed \(totalChunks) chunks. Did you hear a 440Hz tone on the device?")
        audioStream.close()
        setupResult.eventConnection.close()
    } catch AirPlayStreamSetup.StreamError.unexpectedStatus(let code, let body) {
        print("\nFAIL: unexpected status \(code), body (\(body.count) bytes): \(String(data: Data(body), encoding: .utf8) ?? body.map { String(format: "%02x", $0) }.joined())")
        connection.close()
        exit(1)
    } catch {
        print("\nFAIL: \(error)")
        connection.close()
        exit(1)
    }
    connection.close()

default:
    print("Unknown mode \"\(mode)\" — use \"verify\", \"setup\", \"stream\", \"realtime-setup\", or \"tone\".")
    exit(1)
}
exit(0)
