import CryptoKit
import Foundation

/// Builds encrypted RTP datagrams for the native AirPlay 2 realtime stream.
public final class AirPlayRealtimeAudioStream {
    private let udpPort: AirPlayUDPPort
    private let receiverIPv4: String
    private let receiverPort: UInt16
    private let audioKey: SymmetricKey
    private var sequence: UInt16
    /// Recently sent datagrams by sequence number, for answering the
    /// receiver's retransmit requests (`0xD5`). 512 packets is ~4 s.
    private var history = [[UInt8]?](repeating: nil, count: 512)
    private var historySequence = [UInt16](repeating: 0, count: 512)
    private let lock = NSLock()
    public private(set) var resentPackets = 0
    public private(set) var unavailableResends = 0

    public init(
        udpPort: AirPlayUDPPort,
        receiverIPv4: String,
        receiverPort: UInt16,
        audioKey: [UInt8],
        initialSequence: UInt16 = 0
    ) {
        self.udpPort = udpPort
        self.receiverIPv4 = receiverIPv4
        self.receiverPort = receiverPort
        self.audioKey = SymmetricKey(data: Data(audioKey))
        sequence = initialSequence
    }

    public func sendFrame(_ encodedAudio: [UInt8], timestamp: UInt32, isFirst: Bool) throws {
        var header = [UInt8](repeating: 0, count: 12)
        header[0] = 0x80
        // OwnTones never sets the marker bit on realtime audio packets.
        header[1] = 0x60
        writeUInt16(sequence, to: &header, at: 2)
        writeUInt32(timestamp, to: &header, at: 4)
        writeUInt32(0, to: &header, at: 8)

        let sequenceLE = UInt64(sequence).littleEndian
        var nonceSuffix = [UInt8](repeating: 0, count: 8)
        withUnsafeBytes(of: sequenceLE) { bytes in
            nonceSuffix = Array(bytes)
        }
        let nonce = try ChaChaPoly.Nonce(data: Data([0, 0, 0, 0] + nonceSuffix))
        let aad = Data(header[4..<12])
        let sealed = try ChaChaPoly.seal(Data(encodedAudio), using: audioKey, nonce: nonce, authenticating: aad)

        var packet = header
        packet.append(contentsOf: sealed.ciphertext)
        packet.append(contentsOf: sealed.tag)
        packet.append(contentsOf: nonceSuffix)
        lock.withLock {
            let slot = Int(sequence) % history.count
            history[slot] = packet
            historySequence[slot] = sequence
        }
        sequence &+= 1
        if let dropEvery = Self.debugDropEvery, Int(sequence) % dropEvery == 0 {
            return // simulated loss; still in history for retransmit
        }
        try udpPort.send(packet, to: receiverIPv4, port: receiverPort)
    }

    /// `SOUNDCAST_DEBUG_DROP_EVERY=N` skips sending every Nth packet, to
    /// exercise the receiver's retransmit requests on a loss-free LAN.
    private static let debugDropEvery: Int? = {
        guard let raw = ProcessInfo.processInfo.environment["SOUNDCAST_DEBUG_DROP_EVERY"],
              let value = Int(raw), value > 1 else { return nil }
        return value
    }()

    public var resendStats: (resent: Int, unavailable: Int) {
        lock.withLock { (resentPackets, unavailableResends) }
    }

    /// Resends `count` packets starting at `first` (sequence numbers wrap),
    /// byte-identical to the originals — the nonce is the sequence number,
    /// so a resend is exactly the packet that was lost.
    public func resend(first: UInt16, count: UInt16) {
        for offset in 0..<min(count, 128) {
            let wanted = first &+ offset
            let packet: [UInt8]? = lock.withLock {
                let slot = Int(wanted) % history.count
                return historySequence[slot] == wanted ? history[slot] : nil
            }
            if let packet {
                try? udpPort.send(packet, to: receiverIPv4, port: receiverPort)
                lock.withLock { resentPackets += 1 }
            } else {
                lock.withLock { unavailableResends += 1 }
            }
        }
    }

    private func writeUInt16(_ value: UInt16, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    private func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}