import AudioToolbox
import CoreAudio
import Foundation

/// Renders the captured audio to every ticked local Core Audio device
/// (design doc §3) via a private aggregate device with drift
/// compensation on each sub-device — the same mechanism Audio MIDI
/// Setup's "Create Multi-Output Device" uses, reused here instead of
/// hand-rolled resampling. Per-device gain is applied in the render
/// callback (not via the aggregate itself, which doesn't expose
/// independent sub-device volume); master volume is one more
/// multiplication on top.
///
/// ⚠️ Same honesty note as ProcessTapCapture.swift: unbuilt, unverified
/// against a real compiler. The aggregate-device dictionary keys and
/// channel-layout assumption (every sub-device is stereo, channels
/// concatenated in the order listed) match Apple's documented aggregate
/// device behavior as I understand it, but this needs real-hardware
/// testing to confirm, especially for any non-stereo device.
public final class LocalOutputEngine {

    public struct Target {
        public let device: SoundDevice
        public var gain: Float // 0.0...1.0, this device's own slider
        public init(device: SoundDevice, gain: Float) {
            self.device = device
            self.gain = gain
        }
    }

    private(set) public var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let sourceRingBuffer: RingBuffer
    private var channelOffsets: [String: Int] = [:] // device UID -> first channel index in the aggregate
    private var targets: [Target] = []
    public var masterGain: Float = 1.0

    public init(sourceRingBuffer: RingBuffer) {
        self.sourceRingBuffer = sourceRingBuffer
    }

    public enum OutputError: Error {
        case noTargets
        case failedToCreateAggregateDevice(OSStatus)
        case failedToStartIO(OSStatus)
    }

    /// Rebuilds the output aggregate device for the current target set.
    /// Call whenever the user's ticked-device selection changes — this
    /// tears down and recreates the aggregate rather than trying to
    /// mutate it live, which is simpler and, for a handful of local
    /// devices, cheap enough to do on every selection change.
    public func reconfigure(targets: [Target]) throws {
        stop()
        self.targets = targets
        guard !targets.isEmpty else { throw OutputError.noTargets }

        var subDeviceList: [[String: Any]] = []
        channelOffsets.removeAll()
        var runningChannelOffset = 0
        for target in targets {
            channelOffsets[target.device.id] = runningChannelOffset
            subDeviceList.append([
                kAudioSubDeviceUIDKey as String: target.device.id,
                kAudioSubDeviceDriftCompensationKey as String: true,
            ])
            // Simplifying assumption, flagged in the file header: each
            // sub-device contributes 2 channels (stereo) to the
            // aggregate's concatenated channel list. True for built-in
            // speakers and virtually all Bluetooth output devices; a
            // multichannel interface ticked here would need this to
            // read that device's actual channel count instead of a
            // hardcoded 2.
            runningChannelOffset += 2
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SoundCast-Internal-Output",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: subDeviceList,
            kAudioAggregateDeviceMainSubDeviceKey as String: targets[0].device.id,
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard status == noErr else {
            throw OutputError.failedToCreateAggregateDevice(status)
        }
        aggregateDeviceID = newAggregateID
        try startIOProc(on: newAggregateID)
    }

    /// Update one device's slider without tearing down the aggregate.
    public func setGain(deviceID: String, gain: Float) {
        if let index = targets.firstIndex(where: { $0.device.id == deviceID }) {
            targets[index].gain = gain
        }
    }

    public func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
    }

    // MARK: - IOProc: reads from the ring buffer, fans out with per-device gain

    private func startIOProc(on deviceID: AudioObjectID) throws {
        let ringBuffer = sourceRingBuffer
        var newProcID: AudioDeviceIOProcID?

        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, deviceID, nil
        ) { [weak self] _, _, _, outputData, _ in
            guard let self else { return }

            // AudioBufferList is a C "struct hack" (variable-length
            // array: mNumberBuffers followed by that many AudioBuffer
            // structs, extending past the nominally-one-element
            // mBuffers field when mNumberBuffers > 1). Copying it by
            // value (`outputData.pointee`) and taking a pointer to the
            // copy's mBuffers — what this code used to do — only
            // captures buffer[0]; reading buffers[1+] from that copy
            // reads garbage stack memory. Confirmed the hard way: this
            // crashed (SIGSEGV, null dereference) the first time this
            // ran with more than one target device. Apple's own
            // `UnsafeMutableAudioBufferListPointer` overlay exists
            // specifically to iterate the real, uncopied buffer list
            // correctly — use that instead of hand-rolled pointer math.
            let bufferList = UnsafeMutableAudioBufferListPointer(outputData)

            // Pull one block of the shared stereo source once per
            // callback, then fan it out (with per-device gain) into
            // every target's own buffer.
            guard let firstBuffer = bufferList.first, firstBuffer.mDataByteSize > 0 else { return }
            let frameCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size / 2
            guard frameCount > 0 else { return }
            var sourceStereo = [Float](repeating: 0, count: frameCount * 2)
            sourceStereo.withUnsafeMutableBufferPointer { ptr in
                ringBuffer.read(into: ptr.baseAddress!, count: frameCount * 2)
            }

            // Buffers and targets are built in the same order (the
            // subDeviceList order from reconfigure(targets:)), so pair
            // them by index — each sub-device's buffer gets only *its
            // own* device's gain applied, not every target's gain
            // cross-multiplied into every buffer.
            for (index, buffer) in bufferList.enumerated() {
                guard let data = buffer.mData, index < self.targets.count else { continue }
                let channelCount = Int(buffer.mNumberChannels) // real field, not inferred
                guard channelCount > 0 else { continue }
                let target = self.targets[index]
                let gain = target.gain * self.masterGain
                data.withMemoryRebound(to: Float.self, capacity: frameCount * channelCount) { outPtr in
                    for frame in 0..<frameCount {
                        for channel in 0..<min(2, channelCount) {
                            outPtr[frame * channelCount + channel] = sourceStereo[frame * 2 + channel] * gain
                        }
                    }
                }
            }
        }
        guard createStatus == noErr, let procID = newProcID else {
            throw OutputError.failedToStartIO(createStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            throw OutputError.failedToStartIO(startStatus)
        }
    }
}
