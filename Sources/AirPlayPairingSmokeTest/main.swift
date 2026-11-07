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
        print("Usage: AirPlayPairingSmokeTest realtime-setup <ipv6-link-local-address> <interface-name> <receiver-ipv4> [port]")
        exit(1)
    }
    let receiverIPv4 = args[3]
    let port = args.count >= 5 ? (UInt16(args[4]) ?? 7000) : 7000
    let audioDuration = args.count >= 6 ? (Double(args[5]) ?? 0) : 0
    let ptpClock = try AirPlayPTPClock(peerIPv4: receiverIPv4)
    defer { ptpClock.stop() }
    ptpClock.start()
    let controlSocket = try AirPlayUDPPort(localAddress: ptpClock.localAddress)
    let dataSocket = try AirPlayUDPPort(localAddress: ptpClock.localAddress)
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
        print("Negotiating realtime type=96 with the local PTP clock...")
        let setupResult = try await AirPlayStreamSetup.run(
            connection: connection,
            host: host,
            requestTarget: requestTarget,
            sessionUUID: sessionUUID,
            sharedKey: audioKey,
            samplesPerFrame: 352,
            timingProtocol: "PTP",
            ptpClock: ptpClock,
            streamType: 96,
            localControlPort: controlSocket.port,
            localDataPort: dataSocket.port,
            streamConnectionID: streamConnectionID,
            recordBeforeStream: true
        )
        print("Realtime SETUP accepted: localDataPort=\(dataSocket.port) remoteDataPort=\(setupResult.dataPort) controlPort=\(setupResult.controlPort)")
        let volumeResponse = try await connection.send(
            method: "SET_PARAMETER",
            path: requestTarget,
            extraHeaders: AirPlayStreamSetup.streamHeaders.merging(["Content-Type": "text/parameters"]) { _, new in new },
            body: Array("volume: 0.000000\r\n".utf8)
        )
        print("SET_PARAMETER volume -> status \(volumeResponse.statusCode)")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let probes = ptpClock.probeCounts()
        print("PTP requests: Delay_Req=\(probes.delayRequests) Pdelay_Req=\(probes.peerDelayRequests) Signaling=\(probes.signalingRequests) grants=\(probes.signalingGrants) types=\(probes.requestedMessageTypes)")
        if audioDuration > 0 {
            let sampleRate = 44_100.0
            let encoder = try ALACEncoder(
                inputSampleRate: sampleRate,
                outputSampleRate: sampleRate,
                framesPerPacket: 352
            )
            let stream = AirPlayRealtimeAudioStream(
                udpPort: dataSocket,
                receiverIPv4: receiverIPv4,
                receiverPort: UInt16(setupResult.dataPort),
                audioKey: audioKey,
                initialSequence: UInt16.random(in: 0...UInt16.max)
            )
            let ntpEpochOffset = 2_208_988_800.0
            let startTime = Date().timeIntervalSince1970 + ntpEpochOffset + 2.0
            var sampleTimestamp = UInt32(truncatingIfNeeded: Int64(startTime * sampleRate))
            try controlSocket.send(
                ptpClock.realtimeSyncPacket(rtpTimestamp: sampleTimestamp, first: true),
                to: receiverIPv4,
                port: UInt16(setupResult.controlPort)
            )
            let packetCount = Int(audioDuration * sampleRate / 352.0)
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
                        ptpClock.realtimeSyncPacket(rtpTimestamp: sampleTimestamp, first: false),
                        to: receiverIPv4,
                        port: UInt16(setupResult.controlPort)
                    )
                }
                if packetIndex == 0 {
                    print("Sent first realtime ALAC/RTP packet (\(encoded.count) encoded bytes).")
                }
                try await Task.sleep(nanoseconds: UInt64(352.0 / sampleRate * 1_000_000_000))
            }
            print("Sent \(packetCount) realtime audio packet(s).")
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
