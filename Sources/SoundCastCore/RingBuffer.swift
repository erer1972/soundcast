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
public final class RingBuffer {
    private var storage: [Float]
    private let capacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()

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
        for i in 0..<sampleCount {
            storage[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % capacity
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
