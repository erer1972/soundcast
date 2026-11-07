import AVFAudio
import Foundation

/// Encodes interleaved Float32 PCM into ALAC (Apple Lossless) frames via
/// `AVAudioConverter`. Classic AirPlay/RAOP has historically used ALAC
/// rather than AAC for device-to-device streaming — tried after AAC (with
/// six independent crypto/framing variations ruled out) consistently got
/// ACKed-then-reset by a real Apple TV on the `dataPort` channel.
/// `audioFormat` `0x00040000` (confirmed from a public AirPlay2 sender
/// reference's own doc comment: "AP2 audio format bit values... e.g.
/// 0x00040000 is ALAC/44100/16/2") replaces the unconfirmed AAC value
/// used before.
public final class ALACEncoder {
    public enum EncoderError: Error {
        case formatCreationFailed
        case converterCreationFailed
        case conversionFailed(String)
    }

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    public let samplesPerFrame: Int

    public init(
        inputSampleRate: Double = 48_000,
        outputSampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2,
        framesPerPacket: Int = 4096
    ) throws {
        guard framesPerPacket > 0 else { throw EncoderError.formatCreationFailed }
        guard let inFmt = AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: channels) else {
            throw EncoderError.formatCreationFailed
        }
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatAppleLossless,
            // Must be explicit: with flags 0 and Float32 input, Core Audio
            // encodes 32-bit ALAC (cookie bitDepth 0x20, ~1606-byte packets
            // for 352 frames), but AirPlay's audioFormat 0x40000 tells the
            // receiver to decode 16-bit. Verified on the Mac Pro 2026-11-07.
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
            mBytesPerPacket: 0,
            mFramesPerPacket: AVAudioFrameCount(framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let outFmt = AVAudioFormat(streamDescription: &outDesc) else {
            throw EncoderError.formatCreationFailed
        }
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw EncoderError.converterCreationFailed
        }
        converter = conv
        inputFormat = inFmt
        outputFormat = outFmt
        samplesPerFrame = framesPerPacket
    }

    /// Encodes one chunk of interleaved Float32 samples (at `inputFormat`'s
    /// sample rate/channel count) into zero or more ALAC frames (typically
    /// one, at `samplesPerFrame` output samples each).
    public func encode(interleavedSamples: [Float]) throws -> [[UInt8]] {
        let channelCount = Int(inputFormat.channelCount)
        let frameCount = interleavedSamples.count / channelCount
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw EncoderError.conversionFailed("could not allocate input buffer")
        }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = inputBuffer.floatChannelData else {
            throw EncoderError.conversionFailed("no floatChannelData")
        }
        for ch in 0..<channelCount {
            for frame in 0..<frameCount {
                channelData[ch][frame] = interleavedSamples[frame * channelCount + ch]
            }
        }

        final class ConversionState: @unchecked Sendable {
            let inputBuffer: AVAudioPCMBuffer
            var inputConsumed = false
            init(inputBuffer: AVAudioPCMBuffer) { self.inputBuffer = inputBuffer }
        }
        let state = ConversionState(inputBuffer: inputBuffer)

        var frames: [[UInt8]] = []
        var conversionError: Error?
        while true {
            let outputBuffer = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1, maximumPacketSize: 65536)
            var nsError: NSError?
            let status = converter.convert(to: outputBuffer, error: &nsError) { _, outStatus in
                if state.inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                state.inputConsumed = true
                outStatus.pointee = .haveData
                return state.inputBuffer
            }
            if let nsError {
                conversionError = EncoderError.conversionFailed("\(nsError)")
                break
            }
            if outputBuffer.byteLength > 0 {
                let bytes = Array(UnsafeBufferPointer(
                    start: outputBuffer.data.assumingMemoryBound(to: UInt8.self),
                    count: Int(outputBuffer.byteLength)
                ))
                frames.append(bytes)
            }
            if status != .haveData {
                break
            }
        }
        if let conversionError { throw conversionError }
        return frames
    }
}
