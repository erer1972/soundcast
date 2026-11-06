import CryptoKit
import Foundation

/// AirPlay/HomeKit pair-setup: first-time trust establishment between
/// this sender's identity (AirPlayIdentity) and a receiver, using SRP-6a
/// authenticated by the PIN the receiver displays on screen after a
/// `/pair-pin-start` request.
///
/// **Verified end-to-end against a real Apple TV** (design doc §12.5):
/// a fresh SoundCast identity, never seen by the device before, ran this
/// full flow — SRP-6a key exchange, M5/M6 LTPK exchange with Ed25519
/// signature verification both directions — and the device accepted it;
/// a subsequent pair-verify using the now-persisted identity succeeded
/// too, proving the pairing actually stuck.
///
/// Getting here needed two real fixes, both found by cross-checking an
/// independent Python reimplementation against live-captured
/// intermediate values rather than guessing:
/// 1. **The receiver's own access-control gate** (a custom
///    `470 Connection Authorization Required` from the Apple TV) blocks
///    pair-setup from any sender the device hasn't been told to expect.
///    `/pair-pin-start` only actually displays a PIN if its triggering
///    connection is kept open afterward — closing it right away
///    silently suppresses the PIN with no error. The real flow is:
///    trigger pair-pin-start, keep that connection open, read the PIN
///    off the device's screen, then run the SRP exchange on that same
///    connection.
/// 2. **A real math bug**, not a wrong assumption: the SRP "M1" client
///    proof must hash `g`, `N`, `A`, and `B` as their *minimal*
///    big-endian bytes, not padded to the group's 384-byte length —
///    padding is only correct for computing `k` and `u`. Hashing `g`
///    (the single byte `0x05`) padded to 384 mostly-zero bytes produced
///    a completely different digest than the real device expected,
///    which an independent Python SRP reimplementation (cross-checked
///    against a public AirPlay sender reference) caught.
public enum AirPlayPairSetup {
    public enum PairSetupError: Error {
        case rejected(errorCode: UInt8)
        case malformedResponse
        case srpFailed
        case serverProofMismatch
        case signatureVerificationFailed
    }

    /// Triggers the receiver to display a PIN on screen. Confirmed live:
    /// this only actually shows a PIN if the triggering connection is
    /// kept open afterward — closing it right away (as a short-lived
    /// probe would) silently suppresses the PIN, with no error telling
    /// you so. Call this, read the PIN off the device, then call
    /// `completeSetup` on the *same* still-open connection.
    public static func startPinFlow(connection: AirPlayRTSPConnection) async throws {
        _ = try await connection.send(method: "POST", path: "/pair-pin-start")
    }

    /// Convenience wrapper for when the setup code is already known in
    /// advance (e.g. a fixed/transient code) and there's no need to
    /// pause for a human to read a screen between the two steps.
    public static func run(
        connection: AirPlayRTSPConnection,
        identity: AirPlayIdentity,
        setupCode: String,
        transient: Bool
    ) async throws {
        try await startPinFlow(connection: connection)
        try await completeSetup(connection: connection, identity: identity, setupCode: setupCode, transient: transient)
    }

    public static func completeSetup(
        connection: AirPlayRTSPConnection,
        identity: AirPlayIdentity,
        setupCode: String,
        transient: Bool
    ) async throws {
        var m1 = TLV8()
        m1.set(TLV8Tag.state, byte: 1)
        m1.set(TLV8Tag.method, byte: 0)
        if transient {
            m1.set(TLV8Tag.flags, byte: 0x10)
        }
        let m2Response = try await connection.send(
            method: "POST", path: "/pair-setup",
            extraHeaders: AirPlayRTSPConnection.pairingHeaders,
            body: m1.encoded()
        )
        let m2 = try decodeOrThrow(m2Response)
        guard let salt = m2[TLV8Tag.salt], let serverPublicKeyB = m2[TLV8Tag.publicKey] else {
            throw PairSetupError.malformedResponse
        }

        let session = SRP6a.startSession()
        guard let srpResult = SRP6a.respond(
            session: session,
            username: "Pair-Setup",
            password: setupCode,
            salt: salt,
            serverPublicKeyB: serverPublicKeyB
        ) else {
            throw PairSetupError.srpFailed
        }

        var m3 = TLV8()
        m3.set(TLV8Tag.state, byte: 3)
        m3.set(TLV8Tag.publicKey, srpResult.publicKeyA)
        m3.set(TLV8Tag.proof, srpResult.proofM1)
        let m4Response = try await connection.send(
            method: "POST", path: "/pair-setup",
            extraHeaders: AirPlayRTSPConnection.pairingHeaders,
            body: m3.encoded()
        )
        let m4 = try decodeOrThrow(m4Response)
        guard let serverProof = m4[TLV8Tag.proof], serverProof == srpResult.expectedServerProofM2 else {
            throw PairSetupError.serverProofMismatch
        }

        if transient {
            // Per community research (unverified): transient pairing may
            // stop here with no LTPK exchange — the SRP session key alone
            // becomes the trust basis for this session. If a real device
            // instead expects an M5-shaped request, this needs revisiting
            // once tested live.
            return
        }

        let sessionKey = SymmetricKey(data: srpResult.sessionKeyK)
        let encryptKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data("Pair-Setup-Encrypt-Salt".utf8),
            info: Data("Pair-Setup-Encrypt-Info".utf8),
            outputByteCount: 32
        )
        let controllerSignKeyMaterial = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
            info: Data("Pair-Setup-Controller-Sign-Info".utf8),
            outputByteCount: 32
        )
        let accessorySignKeyMaterial = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data("Pair-Setup-Accessory-Sign-Salt".utf8),
            info: Data("Pair-Setup-Accessory-Sign-Info".utf8),
            outputByteCount: 32
        )

        var m5Inner = TLV8()
        let controllerIdentifierBytes = Array(identity.pairingID.utf8)
        let signedMessage = controllerSignKeyMaterial.withUnsafeBytes { Array($0) }
            + controllerIdentifierBytes + identity.publicKeyBytes
        let signature = try identity.signingKey.signature(for: Data(signedMessage))
        m5Inner.set(TLV8Tag.identifier, controllerIdentifierBytes)
        m5Inner.set(TLV8Tag.publicKey, identity.publicKeyBytes)
        m5Inner.set(TLV8Tag.signature, Array(signature))

        let m5EncryptedPayload = try sealBox(plaintext: m5Inner.encoded(), key: encryptKey, nonceLabel: "PS-Msg05")
        var m5 = TLV8()
        m5.set(TLV8Tag.state, byte: 5)
        m5.set(TLV8Tag.encryptedData, m5EncryptedPayload)
        let m6Response = try await connection.send(
            method: "POST", path: "/pair-setup",
            extraHeaders: AirPlayRTSPConnection.pairingHeaders,
            body: m5.encoded()
        )
        let m6 = try decodeOrThrow(m6Response)
        guard let m6EncryptedPayload = m6[TLV8Tag.encryptedData] else {
            throw PairSetupError.malformedResponse
        }
        let m6PlainText = try openSealedBox(ciphertext: m6EncryptedPayload, key: encryptKey, nonceLabel: "PS-Msg06")
        let m6Inner = TLV8(decoding: m6PlainText)
        guard let accessoryIdentifier = m6Inner[TLV8Tag.identifier],
              let accessoryPublicKeyBytes = m6Inner[TLV8Tag.publicKey],
              let accessorySignature = m6Inner[TLV8Tag.signature] else {
            throw PairSetupError.malformedResponse
        }
        let accessoryVerifyKey = try Curve25519.Signing.PublicKey(rawRepresentation: accessoryPublicKeyBytes)
        let accessorySignedMessage = accessorySignKeyMaterial.withUnsafeBytes { Array($0) }
            + accessoryIdentifier + accessoryPublicKeyBytes
        guard accessoryVerifyKey.isValidSignature(accessorySignature, for: Data(accessorySignedMessage)) else {
            throw PairSetupError.signatureVerificationFailed
        }
        // Trust-on-first-use storage of accessoryPublicKeyBytes/accessoryIdentifier
        // (keyed by device) is needed before pair-verify can be used
        // against this specific accessory going forward — not yet built;
        // tracked as a follow-up once this flow itself is verified live.
    }

    private static func decodeOrThrow(_ response: AirPlayRTSPConnection.Response) throws -> TLV8 {
        let tlv = TLV8(decoding: response.body)
        if let errorByte = tlv[TLV8Tag.error]?.first {
            throw PairSetupError.rejected(errorCode: errorByte)
        }
        return tlv
    }
}
