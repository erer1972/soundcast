import CryptoKit
import Foundation
import Network

/// Sends encrypted AAC-LC frames over the `dataPort` TCP connection AirPlay
/// RTSP SETUP (stream `type=103`, "buffered") negotiates.
///
/// *** NOT YET VERIFIED AGAINST A LIVE DEVICE. *** The wire format below
/// comes from reading a real AirPlay 2 *receiver* implementation's
/// decryption code (`openairplay2`'s buffered-audio module, which itself
/// says it follows shairport's `ap2_buffered_audio_processor.c` — not
/// independently confirmed against a real sender's bytes the way
/// pairing/SETUP/RECORD were). Per-TCP-block frame:
/// `[u16 length, big-endian, includes these 2 bytes][seq:4 BE (24-bit
/// used)][timestamp:4 BE][ssrc:4 BE][ChaCha20-Poly1305 ciphertext][16-byte
/// tag][8-byte nonce suffix]`. The 32-byte `shk` sent during SETUP phase 2
/// is used directly as the ChaCha20-Poly1305 key (no HKDF). The 12-byte
/// nonce is 4 zero bytes followed by the 8-byte suffix (sent in the
/// clear, at the end of the packet); the AAD is bytes 4..12 of the
/// packet (timestamp + SSRC — the sequence number itself isn't
/// authenticated).
public final class AirPlayAudioStream: @unchecked Sendable {
    private let connection: NWConnection
    private let key: SymmetricKey
    private let ssrc: UInt32
    private var sequence: UInt32 = 0

    public init(host: NWEndpoint.Host, port: NWEndpoint.Port, sharedKey: [UInt8]) {
        connection = NWConnection(host: host, port: port, using: .tcp)
        key = SymmetricKey(data: sharedKey)
        ssrc = UInt32.random(in: 0...UInt32.max)
    }

    public enum StreamError: Error {
        case connectFailed(String)
        case sendFailed(String)
    }

    public func connect() async throws {
        // NWConnection can report .failed more than once for the same
        // attempt (confirmed live: a "connection reset by peer" failure
        // crashed the process by resuming this continuation twice,
        // before this guard existed) — resume exactly once regardless.
        final class ResumeGuard: @unchecked Sendable {
            var didResume = false
        }
        let resumeGuard = ResumeGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard !resumeGuard.didResume else { return }
                switch state {
                case .ready:
                    resumeGuard.didResume = true
                    continuation.resume()
                case .failed(let error):
                    resumeGuard.didResume = true
                    continuation.resume(throwing: StreamError.connectFailed("\(error)"))
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    public func close() {
        connection.cancel()
    }

    /// Encrypts and sends one AAC-LC frame. `timestamp` is the running
    /// sample count at the start of this frame (e.g. incrementing by the
    /// frame's sample-per-frame count, 1024 for AAC-LC, each call).
    public func sendFrame(aacData: [UInt8], timestamp: UInt32) async throws {
        let seq = sequence & 0xFF_FFFF
        sequence += 1

        var nonceSuffix = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { nonceSuffix[i] = UInt8.random(in: 0...255) }
        var nonceBytes = [UInt8](repeating: 0, count: 4)
        nonceBytes.append(contentsOf: nonceSuffix)
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)

        // Receiver reads these 4 bytes as a big-endian u32 then masks to
        // the low 24 bits (`& 0xFF_FFFF`) — so the 24-bit seq value goes
        // in the LAST 3 bytes (MSB first); the first byte is discarded
        // by that mask regardless of what's in it.
        var header = [UInt8]()
        header.append(0)
        header.append(UInt8((seq >> 16) & 0xFF))
        header.append(UInt8((seq >> 8) & 0xFF))
        header.append(UInt8(seq & 0xFF))
        header.append(UInt8((timestamp >> 24) & 0xFF))
        header.append(UInt8((timestamp >> 16) & 0xFF))
        header.append(UInt8((timestamp >> 8) & 0xFF))
        header.append(UInt8(timestamp & 0xFF))
        header.append(UInt8((ssrc >> 24) & 0xFF))
        header.append(UInt8((ssrc >> 16) & 0xFF))
        header.append(UInt8((ssrc >> 8) & 0xFF))
        header.append(UInt8(ssrc & 0xFF))

        let aad = Data(header[4..<12])
        let sealed = try ChaChaPoly.seal(aacData, using: key, nonce: nonce, authenticating: aad)

        if ProcessInfo.processInfo.environment["DEBUG_AUDIO"] != nil {
            let keyHex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
            FileHandle.standardError.write("[AUDIO DEBUG] key=\(keyHex)\n".data(using: .utf8)!)
            FileHandle.standardError.write("[AUDIO DEBUG] seq=\(seq) timestamp=\(timestamp) ssrc=\(ssrc) aacLen=\(aacData.count)\n".data(using: .utf8)!)
            // Round-trip self-check: catches a bug in this code's own
            // use of the CryptoKit API, independent of whether the wire
            // format itself matches what the real receiver expects.
            do {
                let reopened = try ChaChaPoly.open(sealed, using: key, authenticating: aad)
                let matches = Array(reopened) == aacData
                FileHandle.standardError.write("[AUDIO DEBUG] self round-trip decrypt matches original: \(matches)\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write("[AUDIO DEBUG] self round-trip decrypt FAILED: \(error)\n".data(using: .utf8)!)
            }
        }

        var packet = header
        packet.append(contentsOf: sealed.ciphertext)
        packet.append(contentsOf: sealed.tag)
        packet.append(contentsOf: nonceSuffix)

        let totalLength = UInt16(2 + packet.count)
        var frame: [UInt8] = [UInt8((totalLength >> 8) & 0xFF), UInt8(totalLength & 0xFF)]
        frame.append(contentsOf: packet)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(frame), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: StreamError.sendFailed("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
