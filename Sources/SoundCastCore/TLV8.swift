import Foundation

/// Minimal TLV8 (1-byte tag + 1-byte length + value) codec used by
/// AirPlay/HomeKit's pair-setup and pair-verify exchanges. A value over
/// 255 bytes is split into consecutive same-tag chunks on the wire; this
/// codec merges those back into one value when decoding, and splits long
/// values the same way when encoding. The chunking/merge rule comes from
/// the published TLV8 format; the tag values and message shapes below were
/// confirmed against a real captured pair-verify exchange (design doc
/// §12) for every case that exchange exercised (State, PublicKey,
/// EncryptedData, Error, all <=120 bytes — never a chunked value), so the
/// >255-byte chunking path itself is implemented per spec but not yet
/// exercised against a real multi-chunk value.
public struct TLV8 {
    public var entries: [(tag: UInt8, value: [UInt8])] = []

    public init() {}

    public init(decoding bytes: [UInt8]) {
        var values: [UInt8: [UInt8]] = [:]
        var order: [UInt8] = []
        var i = 0
        var previousTagIfContinuable: UInt8?
        while i + 1 < bytes.count {
            let tag = bytes[i]
            let length = Int(bytes[i + 1])
            let valueStart = i + 2
            let valueEnd = min(valueStart + length, bytes.count)
            let value = Array(bytes[valueStart..<valueEnd])
            i = valueEnd
            if tag == previousTagIfContinuable {
                values[tag, default: []].append(contentsOf: value)
            } else {
                values[tag] = value
                order.append(tag)
            }
            previousTagIfContinuable = (length == 255) ? tag : nil
        }
        entries = order.map { ($0, values[$0] ?? []) }
    }

    public subscript(tag: UInt8) -> [UInt8]? {
        entries.first { $0.tag == tag }?.value
    }

    public mutating func set(_ tag: UInt8, _ value: [UInt8]) {
        entries.append((tag, value))
    }

    public mutating func set(_ tag: UInt8, byte: UInt8) {
        set(tag, [byte])
    }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        for (tag, value) in entries {
            if value.isEmpty {
                out.append(tag)
                out.append(0)
                continue
            }
            var offset = 0
            while offset < value.count {
                let chunkLen = min(255, value.count - offset)
                out.append(tag)
                out.append(UInt8(chunkLen))
                out.append(contentsOf: value[offset..<(offset + chunkLen)])
                offset += chunkLen
            }
            // A chunk of exactly 255 bytes is indistinguishable from "more
            // data follows" — add an explicit zero-length terminator so a
            // value that happens to be an exact multiple of 255 isn't
            // misread as truncated.
            if value.count % 255 == 0 {
                out.append(tag)
                out.append(0)
            }
        }
        return out
    }
}

/// Tag values confirmed against a real captured pair-verify exchange
/// (state/publicKey/encryptedData/error) plus the pair-setup tags needed
/// for AirPlayPairSetup.swift, taken from public HAP-implementation
/// research (not yet independently verified live — see that file).
public enum TLV8Tag {
    public static let method: UInt8 = 0x00
    public static let identifier: UInt8 = 0x01
    public static let salt: UInt8 = 0x02
    public static let publicKey: UInt8 = 0x03
    public static let proof: UInt8 = 0x04
    public static let encryptedData: UInt8 = 0x05
    public static let state: UInt8 = 0x06
    public static let error: UInt8 = 0x07
    public static let signature: UInt8 = 0x0A
    public static let flags: UInt8 = 0x13
}
