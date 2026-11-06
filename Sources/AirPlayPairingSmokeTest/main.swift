import Foundation
import Network
import SoundCastCore

// Design doc §12 Phase 2 step 2 smoke test: exercises the real
// AirPlayRTSPConnection/TLV8/ChaCha20-Poly1305 wire protocol against a
// real AirPlay 2 receiver. Since SoundCast's AirPlayIdentity is brand
// new, no real receiver will recognize it yet — a clean TLV8 rejection
// (not a crash, timeout, or malformed-response error) is itself the
// thing this test is checking: proof the request framing and encoding
// genuinely interoperate with real hardware, not just that the Swift
// code compiles and runs standalone.
//
// Usage: AirPlayPairingSmokeTest <ipv6-link-local-address> <interface-name> [port, default 7000]

CPUFeatureGuard.logAndGuard(context: "AirPlayPairingSmokeTest launch")

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("Usage: AirPlayPairingSmokeTest <ipv6-link-local-address> <interface-name> [port]")
    exit(1)
}
let address = args[0]
let interfaceName = args[1]
let port = args.count >= 3 ? (UInt16(args[2]) ?? 7000) : 7000

let identity = AirPlayIdentity.loadOrCreate()
print("Using SoundCast identity pairingID=\(identity.pairingID)")

let host = NWEndpoint.Host("\(address)%\(interfaceName)")
let connection = AirPlayRTSPConnection(host: host, port: NWEndpoint.Port(rawValue: port)!)

do {
    print("Connecting to [\(address)%\(interfaceName)]:\(port)...")
    try await connection.connect()
    print("Connected. Running pair-verify (expected to be rejected — this device doesn't know SoundCast's identity yet)...")
    let keys = try await AirPlayPairVerify.run(connection: connection, identity: identity)
    print("UNEXPECTED SUCCESS: pair-verify completed, got session keys (readKey/writeKey present: \(keys.readKey.withUnsafeBytes { !$0.isEmpty }), \(keys.writeKey.withUnsafeBytes { !$0.isEmpty }))")
    print("\nPASS (surprising): this device already trusts SoundCast's identity somehow.")
} catch AirPlayPairVerify.PairVerifyError.rejected(let errorCode) {
    print("\nPASS: real device cleanly rejected pair-verify with TLV8 Error=\(errorCode) (expected — SoundCast's identity isn't paired with this device). The wire protocol itself worked end-to-end.")
} catch {
    print("\nFAIL: \(error)")
    print("This means the request framing/encoding itself didn't interoperate correctly — not just an expected identity mismatch.")
    connection.close()
    exit(1)
}
connection.close()
exit(0)
