import BigInt
import CryptoKit
import Foundation
import Security

/// SRP-6a client math for AirPlay/HomeKit pair-setup: the RFC 5054
/// Appendix A 3072-bit group, with SHA-512 throughout. Taken from public
/// HAP-implementation research this session, not independently verified
/// against a live device — see AirPlayPairSetup.swift's doc comment for
/// why (every live pair-setup attempt this session was rejected before
/// the SRP exchange itself ever ran).
struct SRP6a {
    static let N: BigUInt = {
        let hex = """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC7\
        4020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1\
        4374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F40\
        6B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A\
        163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F3\
        56208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C329\
        05E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9\
        DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AACA\
        A68FFFFFFFFFFFFFFFF
        """.replacingOccurrences(of: "\n", with: "")
        return BigUInt(hex, radix: 16)!
    }()
    static let g = BigUInt(5)
    static let byteLength = 384 // 3072 bits / 8

    static func pad(_ value: BigUInt) -> [UInt8] {
        var bytes = [UInt8](value.serialize())
        if bytes.count < byteLength {
            bytes = [UInt8](repeating: 0, count: byteLength - bytes.count) + bytes
        }
        return bytes
    }

    static func hash(_ chunks: [[UInt8]]) -> [UInt8] {
        var hasher = SHA512()
        for chunk in chunks { hasher.update(data: Data(chunk)) }
        return Array(hasher.finalize())
    }

    static func bigUInt(fromDigest bytes: [UInt8]) -> BigUInt {
        BigUInt(Data(bytes))
    }

    struct ClientSession {
        let a: BigUInt
        let A: BigUInt
    }

    /// Step 1: the client's ephemeral keypair (a, A = g^a mod N). `a` is
    /// 32 random bytes (256 bits) — most real SRP6a implementations use
    /// a value in this range; the RFC itself only requires "sufficiently
    /// large" randomness, not an exact size.
    static func startSession() -> ClientSession {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let a = bigUInt(fromDigest: randomBytes)
        let A = g.power(a, modulus: N)
        return ClientSession(a: a, A: A)
    }

    struct Result {
        let proofM1: [UInt8]
        let sessionKeyK: [UInt8]
        let expectedServerProofM2: [UInt8]
        let publicKeyA: [UInt8]
    }

    /// Step 2: given the server's salt + B, derive the shared key K and
    /// the client's proof to send back (M1 in SRP's own M1/M2 proof
    /// naming, not to be confused with HAP's M1-M6 message numbering).
    static func respond(
        session: ClientSession,
        username: String,
        password: String,
        salt: [UInt8],
        serverPublicKeyB: [UInt8]
    ) -> Result? {
        let B = BigUInt(Data(serverPublicKeyB))
        guard B % N != BigUInt(0) else { return nil } // reject B=0 (mod N)

        let k = bigUInt(fromDigest: hash([pad(N), pad(g)]))
        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        let x = bigUInt(fromDigest: hash([salt, hash([usernameBytes, [0x3A], passwordBytes])]))
        let u = bigUInt(fromDigest: hash([pad(session.A), pad(B)]))
        guard u != BigUInt(0) else { return nil }

        let v = g.power(x, modulus: N)
        let kv = (k * v) % N
        let base = (B + N - kv) % N
        let exponent = session.a + (u * x)
        let S = base.power(exponent, modulus: N)
        let K = hash([pad(S)])

        let hN = hash([pad(N)])
        let hg = hash([pad(g)])
        let hNxorHg = zip(hN, hg).map { $0 ^ $1 }
        let hI = hash([usernameBytes])
        let proofM1 = hash([hNxorHg, hI, salt, pad(session.A), pad(B), K])
        let proofM2 = hash([pad(session.A), proofM1, K])

        return Result(proofM1: proofM1, sessionKeyK: K, expectedServerProofM2: proofM2, publicKeyA: pad(session.A))
    }
}
