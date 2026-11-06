import CryptoKit
import Foundation

/// SoundCast's own persistent AirPlay/HomeKit pairing identity: a stable
/// Ed25519 keypair plus a random pairing ID, generated once and reused
/// for every device SoundCast pairs with — a real AirPlay sender has one
/// identity it presents to every accessory, not a fresh one per
/// connection (confirmed by the real pair-verify capture this session:
/// macOS's pair-verify only succeeds at all *because* the accessory
/// already recognizes a previously-stored identity from this Mac).
public struct AirPlayIdentity {
    public let pairingID: String
    public let signingKey: Curve25519.Signing.PrivateKey

    public var publicKeyBytes: [UInt8] { Array(signingKey.publicKey.rawRepresentation) }

    private static let storageURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundCast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("airplay-identity.json")
    }()

    private struct Stored: Codable {
        let pairingID: String
        let privateKey: Data
    }

    public static func loadOrCreate() -> AirPlayIdentity {
        if let data = try? Data(contentsOf: storageURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored.privateKey) {
            return AirPlayIdentity(pairingID: stored.pairingID, signingKey: key)
        }
        let identity = AirPlayIdentity(pairingID: UUID().uuidString, signingKey: Curve25519.Signing.PrivateKey())
        let stored = Stored(pairingID: identity.pairingID, privateKey: identity.signingKey.rawRepresentation)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: storageURL, options: .atomic)
        }
        return identity
    }
}
