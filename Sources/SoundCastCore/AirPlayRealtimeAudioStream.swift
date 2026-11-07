import CryptoKit
import Foundation

/// Builds encrypted RTP datagrams for the native AirPlay 2 realtime stream.
public final class AirPlayRealtimeAudioStream {
    private let udpPort: AirPlayUDPPort
    private let receiverIPv4: String
    private let receiverPort: UInt16
    private let audioKey: SymmetricKey
    private var sequence: UInt16

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
        header[1] = isFirst ? 0xE0 : 0x60
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
        try udpPort.send(packet, to: receiverIPv4, port: receiverPort)
        sequence &+= 1
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