import CryptoKit
import Foundation

/// AirPlay/HomeKit pair-setup: first-time trust establishment between
/// this sender's identity (AirPlayIdentity) and a receiver, using SRP-6a
/// authenticated by the PIN the receiver displays on screen after a
/// `/pair-pin-start` request.
///
/// *** NOT YET VERIFIED AGAINST A LIVE DEVICE. *** Every live attempt
/// this session (design doc §12) was rejected by the receiver's own
/// access-control gate — an Apple TV returned a custom RTSP status
/// `470 Connection Authorization Required`, a Sonos speaker returned a
/// plain `403 Forbidden` — before the SRP exchange itself ever ran, even
/// after setting the Apple TV's "Allow Access" to "Anyone on the Same
/// Network" and successfully triggering `/pair-pin-start` (confirmed: a
/// real 4-digit PIN did appear on the TV's screen, meaning that part of
/// the real protocol genuinely exists and responds to a bare RTSP POST).
/// What's implemented below — the message shapes, TLV8 tags, HKDF
/// salt/info strings, SRP group and hash choice — is the best-effort HAP
/// pair-setup flow from public research, not bytes confirmed on the
/// wire. Treat every constant here as a hypothesis to re-verify once a
/// full Swift AirPlay sender (closer to what a real receiver expects
/// than this session's raw Python probes were) can complete a live run.
public enum AirPlayPairSetup {
    public enum PairSetupError: Error {
        case rejected(errorCode: UInt8)
        case malformedResponse
        case srpFailed
        case serverProofMismatch
        case signatureVerificationFailed
    }

    public static func run(
        connection: AirPlayRTSPConnection,
        identity: AirPlayIdentity,
        setupCode: String,
        transient: Bool
    ) async throws {
        _ = try await connection.send(method: "POST", path: "/pair-pin-start")

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
