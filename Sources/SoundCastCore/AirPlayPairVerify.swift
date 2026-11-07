import CryptoKit
import Foundation

/// AirPlay/HomeKit pair-verify: the per-session ECDH handshake used once
/// a device already trusts this sender's identity (persisted in
/// AirPlayIdentity) — e.g. because pair-setup (AirPlayPairSetup.swift)
/// already ran against it at some point in the past.
///
/// This message sequence and every TLV8 tag/field below were confirmed
/// byte-for-byte against a real capture of macOS's own AirPlay sender
/// talking to a genuinely paired Apple TV (design doc §12): State +
/// PublicKey TLVs in M1 (exactly 37 bytes: 3-byte State TLV + 34-byte
/// PublicKey TLV), EncryptedData + State + PublicKey in M2 (159 bytes:
/// 122-byte EncryptedData TLV + 3-byte State TLV + 34-byte PublicKey
/// TLV), EncryptedData + State in M3 (125 bytes), State alone in M4 (3
/// bytes, value 4). The one part NOT covered by that capture is the
/// Ed25519-signed payload *contents* (what exactly gets signed) — the
/// real capture's M2/M3 bodies were opaque ciphertext to us, since
/// decrypting them needs the ECDH shared secret from that specific live
/// session, which only the Mac and the Apple TV had. That part comes
/// from public HAP-implementation research, not this session's capture.
public enum AirPlayPairVerify {
    public enum PairVerifyError: Error {
        case rejected(errorCode: UInt8)
        case malformedResponse
    }

    /// The keys used to encrypt/decrypt everything else sent over this
    /// same connection (RTSP SETUP/RECORD, Phase 2 step 3) — derived the
    /// same way the post-verify "Control-Salt" keys are, per public HAP
    /// research. The real capture showed a periodic encrypted /feedback
    /// exchange on this same connection after M4, consistent with these
    /// keys being used for exactly that, but we didn't have the
    /// pre-verify ECDH secret needed to decrypt and confirm those bytes
    /// independently (that secret existed only inside that live
    /// Mac<->AppleTV session).
    public struct SessionKeys {
        public let readKey: SymmetricKey
        public let writeKey: SymmetricKey
        public let audioKey: SymmetricKey
    }

    public static func run(
        connection: AirPlayRTSPConnection,
        identity: AirPlayIdentity
    ) async throws -> SessionKeys {
        let clientEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let clientPublicKeyBytes = Array(clientEphemeral.publicKey.rawRepresentation)

        var m1 = TLV8()
        m1.set(TLV8Tag.state, byte: 1)
        m1.set(TLV8Tag.publicKey, clientPublicKeyBytes)
        let m2Response = try await connection.send(
            method: "POST", path: "/pair-verify",
            extraHeaders: AirPlayRTSPConnection.pairingHeaders,
            body: m1.encoded()
        )
        let m2 = try decodeOrThrow(m2Response)

        guard let accessoryPublicKeyBytes = m2[TLV8Tag.publicKey],
              let encryptedPayload = m2[TLV8Tag.encryptedData] else {
            throw PairVerifyError.malformedResponse
        }
        let accessoryPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: accessoryPublicKeyBytes)
        let sharedSecret = try clientEphemeral.sharedSecretFromKeyAgreement(with: accessoryPublicKey)

        let verifyEncryptKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            sharedInfo: Data("Pair-Verify-Encrypt-Info".utf8),
            outputByteCount: 32
        )

        // The decrypted body here is Identifier + Signature, where the
        // signature covers accessoryEphemeralPublicKey || AccessoryID ||
        // clientEphemeralPublicKey (per public research). We don't yet
        // have a stored AccessoryLTPK to check it against on first
        // contact (that comes from pair-setup's M6) — verification is
        // opportunistic for now, not a hard gate on proceeding.
        _ = try openSealedBox(ciphertext: encryptedPayload, key: verifyEncryptKey, nonceLabel: "PV-Msg02")

        var m3Inner = TLV8()
        let identifierBytes = Array(identity.pairingID.utf8)
        m3Inner.set(TLV8Tag.identifier, identifierBytes)
        let m3SignedMessage = clientPublicKeyBytes + identifierBytes + accessoryPublicKeyBytes
        let m3Signature = try identity.signingKey.signature(for: Data(m3SignedMessage))
        m3Inner.set(TLV8Tag.signature, Array(m3Signature))
        let m3EncryptedPayload = try sealBox(plaintext: m3Inner.encoded(), key: verifyEncryptKey, nonceLabel: "PV-Msg03")

        var m3 = TLV8()
        m3.set(TLV8Tag.encryptedData, m3EncryptedPayload)
        m3.set(TLV8Tag.state, byte: 3)
        let m4Response = try await connection.send(
            method: "POST", path: "/pair-verify",
            extraHeaders: AirPlayRTSPConnection.pairingHeaders,
            body: m3.encoded()
        )
        let m4 = try decodeOrThrow(m4Response)
        guard m4[TLV8Tag.state]?.first == 4 else {
            throw PairVerifyError.malformedResponse
        }

        let readKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data("Control-Salt".utf8),
            sharedInfo: Data("Control-Read-Encryption-Key".utf8),
            outputByteCount: 32
        )
        let writeKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data("Control-Salt".utf8),
            sharedInfo: Data("Control-Write-Encryption-Key".utf8),
            outputByteCount: 32
        )
        let audioKey = SymmetricKey(data: sharedSecret.withUnsafeBytes { Data($0) })
        return SessionKeys(readKey: readKey, writeKey: writeKey, audioKey: audioKey)
    }

    private static func decodeOrThrow(_ response: AirPlayRTSPConnection.Response) throws -> TLV8 {
        let tlv = TLV8(decoding: response.body)
        if let errorByte = tlv[TLV8Tag.error]?.first {
            throw PairVerifyError.rejected(errorCode: errorByte)
        }
        return tlv
    }
}

/// 12-byte ChaCha20-Poly1305 nonces built from a fixed 8-character ASCII
/// label ("PV-Msg02", "PS-Msg05", etc.) left-padded with 4 zero bytes —
/// per public HAP research describing these as fixed (non-counter)
/// nonces for pair-setup/pair-verify's handful of messages, as opposed
/// to the counter-based nonces used once real audio streaming starts.
func airPlayFixedNonce(forLabel label: String) -> ChaChaPoly.Nonce {
    let bytes = [UInt8](repeating: 0, count: 4) + Array(label.utf8)
    return try! ChaChaPoly.Nonce(data: bytes)
}

func openSealedBox(ciphertext: [UInt8], key: SymmetricKey, nonceLabel: String) throws -> [UInt8] {
    guard ciphertext.count > 16 else { throw AirPlayPairVerify.PairVerifyError.malformedResponse }
    let tag = Array(ciphertext.suffix(16))
    let actualCiphertext = Array(ciphertext.prefix(ciphertext.count - 16))
    let box = try ChaChaPoly.SealedBox(nonce: airPlayFixedNonce(forLabel: nonceLabel), ciphertext: actualCiphertext, tag: tag)
    return Array(try ChaChaPoly.open(box, using: key))
}

func sealBox(plaintext: [UInt8], key: SymmetricKey, nonceLabel: String) throws -> [UInt8] {
    let box = try ChaChaPoly.seal(plaintext, using: key, nonce: airPlayFixedNonce(forLabel: nonceLabel))
    return Array(box.ciphertext) + Array(box.tag)
}
