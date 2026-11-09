import Foundation

/// A single-producer/single-consumer ring buffer of interleaved Float32
/// samples, used to hand audio from the realtime capture callback to the
/// realtime render callback. Both callbacks run on CoreAudio's own
/// realtime threads with hard deadlines, so the index bookkeeping here
/// is guarded by `os_unfair_lock` rather than being fully lock-free: an
/// uncontended `os_unfair_lock` around a few integer updates is a very
/// short, non-blocking-in-practice critical section, which is the
/// pragmatic middle ground a lot of real audio code settles on rather
/// than pulling in an atomics dependency for a two-thread SPSC case.
/// Flagging this rather than calling it "lock-free," which it technically
/// isn't — if profiling on real hardware ever shows contention here,
/// revisit with proper atomics.
///
/// Intentionally single-consumer for Phase 1 (one capture source, one
/// local-output render path). Phase 2/3 add more consumers (each AirPlay
/// sender, the Sonos HTTP stream); at that point this becomes one ring
/// buffer per consumer, all fed by the same capture callback — not a
/// single multi-consumer structure — so each consumer can apply its own
/// read-offset (design doc §6) independently.
/// Shared across threads by design; every access goes through `lock`.
public final class RingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private let capacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()
    private var peakSinceTaken: Float = 0
    // Onset timestamps (mach host time) for sync calibration; off when 0.
    private var onsetThreshold: Float = 0
    private var onsetHostTimes: [UInt64] = []
    private var lastOnsetHostTime: UInt64 = 0

    public init(capacitySamples: Int) {
        capacity = capacitySamples
        storage = [Float](repeating: 0, count: capacitySamples)
    }

    /// Extra consumers (one per AirPlay sender) that receive a copy of
    /// every write, so one capture callback can feed several consumers
    /// that each read at their own pace (design doc §6).
    private var mirrors: [RingBuffer] = []

    public func addMirror(_ mirror: RingBuffer) {
        os_unfair_lock_lock(&lock)
        mirrors.append(mirror)
        os_unfair_lock_unlock(&lock)
    }

    public func removeMirror(_ mirror: RingBuffer) {
        os_unfair_lock_lock(&lock)
        mirrors.removeAll { $0 === mirror }
        os_unfair_lock_unlock(&lock)
    }

    /// Producer side — call only from the capture callback.
    public func write(_ samples: UnsafePointer<Float>, count sampleCount: Int) {
        os_unfair_lock_lock(&lock)
        var peak = peakSinceTaken
        var blockPeak: Float = 0
        for i in 0..<sampleCount {
            let sample = samples[i]
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            blockPeak = max(blockPeak, abs(sample))
        }
        peak = max(peak, blockPeak)
        peakSinceTaken = peak.isFinite ? peak : 0
        if onsetThreshold > 0, blockPeak > onsetThreshold {
            let now = mach_absolute_time()
            if now &- lastOnsetHostTime > Self.hostTicks(seconds: 0.5) {
                onsetHostTimes.append(now)
                lastOnsetHostTime = now
            }
        }
        if count + sampleCount > capacity {
            // Overflow: the oldest samples were overwritten, so move the
            // read position up to the oldest surviving sample instead of
            // leaving it pointing into freshly written data.
            readIndex = writeIndex
        }
        count = min(capacity, count + sampleCount)
        let mirrors = self.mirrors
        os_unfair_lock_unlock(&lock)
        for mirror in mirrors {
            mirror.write(samples, count: sampleCount)
        }
    }

    /// Drops the oldest queued samples so at most `keepSamples` remain
    /// (consumer side). Used to shed a backlog instead of playing it late.
    public func trim(toAtMost keepSamples: Int) {
        os_unfair_lock_lock(&lock)
        if count > keepSamples {
            let drop = count - keepSamples
            readIndex = (readIndex + drop) % capacity
            count = keepSamples
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Starts recording the host time of each sharp onset written (a block
    /// louder than `threshold` after at least 0.5 s), for sync calibration.
    public func startOnsetDetection(threshold: Float) {
        os_unfair_lock_lock(&lock)
        onsetThreshold = threshold
        onsetHostTimes = []
        lastOnsetHostTime = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Stops onset detection and returns the recorded mach host times.
    public func stopOnsetDetection() -> [UInt64] {
        os_unfair_lock_lock(&lock)
        defer { onsetThreshold = 0; onsetHostTimes = []; os_unfair_lock_unlock(&lock) }
        return onsetHostTimes
    }

    private static func hostTicks(seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(seconds * 1_000_000_000 * Double(info.denom) / Double(info.numer))
    }

    /// Loudest absolute sample written since the last call (for level
    /// meters), then resets it.
    public func takePeak() -> Float {
        os_unfair_lock_lock(&lock)
        defer { peakSinceTaken = 0; os_unfair_lock_unlock(&lock) }
        return peakSinceTaken
    }

    /// Discards everything buffered (consumer side).
    public func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = writeIndex
        count = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Consumer side. Writes `sampleCount` samples into `out`,
    /// zero-filling on underrun (silence beats reading stale data).
    public func read(into out: UnsafeMutablePointer<Float>, count sampleCount: Int) {
        os_unfair_lock_lock(&lock)
        let available = min(sampleCount, count)
        for i in 0..<available {
            out[i] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        count = max(0, count - available)
        os_unfair_lock_unlock(&lock)
        if available < sampleCount {
            for i in available..<sampleCount { out[i] = 0 }
        }
    }

    public var framesAvailable: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return count
    }
}
