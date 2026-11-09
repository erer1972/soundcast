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
/// The aggregate runs at its clock device's rate (e.g. 44.1 kHz for many
/// Bluetooth speakers) while the source arrives at `sourceSampleRate`
/// (48 kHz from the SoundCast device) on its own clock, so the render
/// callback pulls through `StreamResampler`, which converts the rate and
/// trims clock drift by holding the source ring at a small fill target.
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
    /// Rate of the audio arriving in the source ring. Set before
    /// `reconfigure(targets:)`; takes effect on the next reconfigure.
    public var sourceSampleRate: Double = 48_000
    /// How late, after capture, local outputs should actually be heard —
    /// e.g. the AirPlay latency when AirPlay rooms play the same source.
    /// The clock device's own output latency is subtracted. Takes effect
    /// on the next reconfigure.
    public var alignmentDelaySeconds: Double = 0
    /// How long after capture the local outputs are heard (reserve +
    /// added delay + the clock device's own latency); 0 when stopped.
    public private(set) var heardLatencySeconds: Double = 0
    private var resampler: StreamResampler?
    private var mixScratch: UnsafeMutablePointer<Float>?
    private static let maxCallbackFrames = 16_384

    public init(sourceRingBuffer: RingBuffer) {
        self.sourceRingBuffer = sourceRingBuffer
    }

    deinit {
        stop()
        mixScratch?.deallocate()
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

        // Bluetooth speakers can't follow another device's clock well (they
        // stuttered as drift-corrected sub-devices), so when one is ticked
        // it becomes the clock device and the others are drift-corrected
        // against it.
        let ordered = targets.filter { $0.device.category == .bluetooth }
            + targets.filter { $0.device.category != .bluetooth }
        self.targets = ordered

        var subDeviceList: [[String: Any]] = []
        channelOffsets.removeAll()
        var runningChannelOffset = 0
        for target in ordered {
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
            kAudioAggregateDeviceMainSubDeviceKey as String: ordered[0].device.id,
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard status == noErr else {
            throw OutputError.failedToCreateAggregateDevice(status)
        }
        aggregateDeviceID = newAggregateID
        let outputRate = Self.nominalSampleRate(of: newAggregateID) ?? sourceSampleRate
        let deviceLatency = ordered[0].device.audioObjectID.map(Self.outputLatencySeconds) ?? 0
        let extraDelay = max(0, alignmentDelaySeconds - deviceLatency)
        heardLatencySeconds = StreamResampler.reserveSeconds + extraDelay + deviceLatency
        resampler = StreamResampler(
            ring: sourceRingBuffer, sourceRate: sourceSampleRate, outputRate: outputRate, extraDelaySeconds: extraDelay
        )
        if mixScratch == nil {
            mixScratch = .allocate(capacity: Self.maxCallbackFrames * 2)
        }
        NSLog("[SoundCast][LocalOutput] aggregate at \(outputRate) Hz, source \(sourceSampleRate) Hz, clock device \(ordered[0].device.name), device latency \(String(format: "%.3f", deviceLatency)) s, added delay \(String(format: "%.3f", extraDelay)) s")
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
        heardLatencySeconds = 0
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
    }

    // MARK: - IOProc: reads from the ring buffer, fans out with per-device gain

    /// Device latency + safety offset + first output stream's latency, in
    /// seconds: how long after rendering the device actually sounds.
    private static func outputLatencySeconds(of deviceID: AudioObjectID) -> Double {
        func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
        }
        var frames = uint32(deviceID, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
            + uint32(deviceID, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
        )
        var stream = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &stream) == noErr, stream != kAudioObjectUnknown {
            frames += uint32(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
        }
        guard let rate = nominalSampleRate(of: deviceID), rate > 0 else { return 0 }
        return Double(frames) / rate
    }

    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    private func startIOProc(on deviceID: AudioObjectID) throws {
        guard let resampler, let mixScratch else { throw OutputError.failedToStartIO(kAudioHardwareUnspecifiedError) }
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
            let firstChannels = max(1, Int(firstBuffer.mNumberChannels))
            let frameCount = min(
                Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size / firstChannels,
                Self.maxCallbackFrames
            )
            guard frameCount > 0 else { return }
            resampler.render(into: mixScratch, frames: frameCount)
            let sourceStereo = mixScratch

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

/// Pulls interleaved stereo from a `RingBuffer` filled at `sourceRate` and
/// produces it at `outputRate` (cubic Hermite interpolation). The step is
/// nudged by at most ±0.5 % to hold the ring near `targetFill`, which
/// absorbs the clock drift between producer and output device; on an
/// underrun it outputs silence and re-buffers to the target first.
/// Only the render thread touches it after construction.
final class StreamResampler: @unchecked Sendable {
    static let reserveSeconds = 0.06
    private let ring: RingBuffer
    private let baseStep: Double          // source frames per output frame
    private let targetFill: Double        // source frames to keep queued
    private let capacityFrames = 32_768
    private let source: UnsafeMutablePointer<Float>  // interleaved stereo
    private var sourceFrames = 0
    private var position = 1.0            // fractional index into `source`
    private var priming = true
    private var smoothedFill = 0.0
    // Diagnostics, logged about every 5 s from the render thread.
    private var callbacks = 0
    private var primingCallbacks = 0
    private var underruns = 0
    private var trims = 0
    private var peak: Float = 0
    private var lastStep = 0.0
    private var lastReport = DispatchTime.now().uptimeNanoseconds

    init(ring: RingBuffer, sourceRate: Double, outputRate: Double, extraDelaySeconds: Double = 0) {
        self.ring = ring
        baseStep = sourceRate / outputRate
        targetFill = sourceRate * (Self.reserveSeconds + extraDelaySeconds)
        source = .allocate(capacity: capacityFrames * 2)
        resetHistory()
    }

    deinit { source.deallocate() }

    private func resetHistory() {
        // One silent frame before the read position, for the cubic's p0.
        source[0] = 0
        source[1] = 0
        sourceFrames = 1
        position = 1
    }

    func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        renderAudio(into: out, frames: frames)
        callbacks += 1
        for i in 0..<(frames * 2) { peak = max(peak, abs(out[i])) }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastReport > 5_000_000_000 {
            NSLog("[SoundCast][LocalOutput] \(callbacks) callbacks of \(frames) frames, priming \(primingCallbacks), underruns \(underruns), trims \(trims), ring \(ring.framesAvailable / 2) frames, step \(String(format: "%.5f", lastStep)), peak \(peak)")
            callbacks = 0; primingCallbacks = 0; underruns = 0; trims = 0; peak = 0
            lastReport = now
        }
    }

    private func renderAudio(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let fill = Double(ring.framesAvailable / 2)
        if priming {
            guard fill >= targetFill else {
                primingCallbacks += 1
                out.update(repeating: 0, count: frames * 2)
                return
            }
            priming = false
            // Start from the reserve, not from whatever piled up before
            // the output existed (otherwise it plays seconds late).
            ring.trim(toAtMost: Int(targetFill) * 2)
            smoothedFill = targetFill
        } else if fill > targetFill * 4 {
            // A backlog far beyond what drift correction can drain
            // (output stalled, device change): drop it at once.
            ring.trim(toAtMost: Int(targetFill) * 2)
            smoothedFill = targetFill
            trims += 1
        }
        smoothedFill += 0.02 * (fill - smoothedFill)
        let error = (smoothedFill - targetFill) / targetFill
        let step = baseStep * (1 + max(-0.005, min(0.005, error * 0.01)))
        lastStep = step

        // Source frames needed: up to the last output frame plus two of
        // look-ahead for the cubic.
        let needed = Int(position + Double(frames - 1) * step) + 3
        if needed > sourceFrames {
            let missing = needed - sourceFrames
            guard needed <= capacityFrames, ring.framesAvailable / 2 >= missing else {
                out.update(repeating: 0, count: frames * 2)
                underruns += 1
                priming = true
                resetHistory()
                return
            }
            ring.read(into: source + sourceFrames * 2, count: missing * 2)
            sourceFrames = needed
        }

        for frame in 0..<frames {
            let index = Int(position)
            let t = Float(position - Double(index))
            for channel in 0..<2 {
                let p0 = source[(index - 1) * 2 + channel]
                let p1 = source[index * 2 + channel]
                let p2 = source[(index + 1) * 2 + channel]
                let p3 = source[(index + 2) * 2 + channel]
                let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
                let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
                let c = -0.5 * p0 + 0.5 * p2
                out[frame * 2 + channel] = ((a * t + b) * t + c) * t + p1
            }
            position += step
        }

        // Keep one frame before the current position; drop the rest.
        let drop = Int(position) - 1
        if drop > 0 {
            let keep = sourceFrames - drop
            if keep > 0 { source.update(from: source + drop * 2, count: keep * 2) }
            sourceFrames = max(0, keep)
            position -= Double(drop)
        }
    }
}
