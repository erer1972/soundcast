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
        print("\nPASS: this device trusts SoundCast's identity and a real encrypted session is established.")
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

default:
    print("Unknown mode \"\(mode)\" — use \"verify\" or \"setup\".")
    exit(1)
}
exit(0)
