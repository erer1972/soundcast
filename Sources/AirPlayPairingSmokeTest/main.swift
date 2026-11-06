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

default:
    print("Unknown mode \"\(mode)\" — use \"verify\", \"setup\", or \"stream\".")
    exit(1)
}
exit(0)
