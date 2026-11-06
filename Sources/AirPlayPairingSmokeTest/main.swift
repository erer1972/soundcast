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
        var sharedKey = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { sharedKey[i] = UInt8.random(in: 0...255) }
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

case "tone":
    let port = args.count >= 4 ? (UInt16(args[3]) ?? 7000) : 7000
    let durationSeconds = args.count >= 5 ? (Double(args[4]) ?? 5.0) : 5.0
    let connection = try await connect(port: port)
    do {
        print("Running pair-verify...")
        let keys = try await AirPlayPairVerify.run(connection: connection, identity: identity)
        connection.enableEncryption(readKey: keys.readKey, writeKey: keys.writeKey)
        let sessionUUID = UUID().uuidString
        let requestTarget = "rtsp://[\(address)]/\(sessionUUID)"
        _ = try await connection.send(method: "OPTIONS", path: requestTarget)
        var sharedKey = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { sharedKey[i] = UInt8.random(in: 0...255) }
        let host = NWEndpoint.Host("\(address)%\(interfaceName)")
        print("Running RTSP SETUP...")
        let setupResult = try await AirPlayStreamSetup.run(
            connection: connection, host: host, requestTarget: requestTarget, sessionUUID: sessionUUID, sharedKey: sharedKey
        )
        print("SETUP ok: dataPort=\(setupResult.dataPort)")
        print("Running RECORD...")
        try await AirPlayStreamSetup.record(connection: connection, requestTarget: requestTarget)
        print("RECORD ok. Sending initial /feedback...")
        // A real macOS sender's encrypted control channel sent a small
        // periodic request (~87 bytes) roughly every 2s, captured earlier
        // this session before IPv6 was understood to be the real
        // channel — almost certainly POST /feedback (a real endpoint per
        // a real receiver's own dispatch table). Never implemented until
        // now; the data connection dying after exactly one real frame is
        // consistent with the receiver treating a silent sender as dead.
        _ = try await connection.send(method: "POST", path: "/feedback", extraHeaders: AirPlayStreamSetup.streamHeaders)
        print("Opening audio data connection...")
        let audioStream = AirPlayAudioStream(host: host, port: NWEndpoint.Port(rawValue: UInt16(setupResult.dataPort))!, sharedKey: sharedKey)
        try await audioStream.connect()
        print("Audio data connection established. Encoding + streaming a \(durationSeconds)s 440Hz tone...")

        let encoder = try AACEncoder()
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
                print("  chunk \(chunkIndex): sending frame #\(timestamp / UInt32(encoder.samplesPerFrame)) size=\(frame.count) bytes")
                try await audioStream.sendFrame(aacData: frame, timestamp: timestamp)
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
    print("Unknown mode \"\(mode)\" — use \"verify\", \"setup\", \"stream\", or \"tone\".")
    exit(1)
}
exit(0)
