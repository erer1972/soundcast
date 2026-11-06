import CSoundCastSHM
import Foundation

/// Reads from the HAL driver's (`HALPlugin/src/driver.c`) shared-memory
/// ring buffer and feeds a `RingBuffer`, so anything an app/web page
/// sends to the system-wide "SoundCast" virtual output device (design
/// doc §7.1) reaches `LocalOutputEngine` the same way Phase 1's
/// `ProcessTapCapture` does — this is the alternative, per-app-selectable
/// capture source, as opposed to the "cast everything" global tap.
///
/// There is no cross-process signaling (no semaphore/condition variable
/// set up between the driver and this reader) — the driver just
/// publishes a monotonically increasing write counter in shared memory
/// and this class polls it on a background thread. This is the same
/// approach used to read a hardware ring buffer without an interrupt
/// callback, just over shared memory instead of hardware registers.
///
/// ⚠️ The struct layout constants below (header field order, ring
/// capacity, channel count) must stay in exact sync with
/// `HALPlugin/src/driver.c`'s `SoundCastSharedRing` struct — there is no
/// shared source of truth between the two codebases (one is C compiled
/// standalone via `clang`, the other is this Swift package), so a
/// future change to one side's layout needs the same change made here
/// by hand.
public final class VirtualDeviceCapture {

    enum Layout {
        // shmName moved to VirtualDevicePreset — one of 5 possible
        // values now, not a single constant (design doc §7.3).
        static let capacityFrames: UInt32 = 48_000 * 4 // must match SOUNDCAST_SHM_CAPACITY_FRAMES in driver.c
        static let channelCount: UInt32 = 2
        static let sampleRateHz: UInt32 = 48_000
        // initialized, writeIndexFrames, capacityFrames, channelCount,
        // sampleRateHz — 5 UInt32 fields, 4 bytes each, no padding
        // (all naturally 4-byte aligned, sequential).
        static let headerSizeBytes = 20
        static let totalSizeBytes = headerSizeBytes + Int(capacityFrames) * Int(channelCount) * MemoryLayout<Float>.size
    }

    private let preset: VirtualDevicePreset

    public enum CaptureError: Error {
        case shmOpenFailed(Int32)
        case mmapFailed(Int32)
        /// The shared memory exists but its header doesn't match what
        /// this code expects — either the driver's layout changed
        /// without updating this file, or (design doc §7.2's flagged,
        /// unresolved tradeoff: the segment is world-writable, mode
        /// 0666, because the driver runs as `_coreaudiod` while this
        /// app runs as the interactive user, and restricting that would
        /// break legitimate access) something else on the machine wrote
        /// bad data into it. Either way, refuse to trust it rather than
        /// read out-of-bounds based on unvalidated header fields.
        case headerValidationFailed(String)
    }

    /// All poll-loop mutable state lives here, not as captured local
    /// `var`s in a `Thread` closure — Swift 6's strict concurrency
    /// checker correctly refuses to let a plain local `var` be mutated
    /// from a concurrently-executing closure (a hard error, not just a
    /// warning, confirmed when this file first tried the simpler
    /// shape). Only the poll thread itself ever touches this object
    /// after `start()` hands it off, so `@unchecked Sendable` is an
    /// honest, narrow opt-out — same pattern used in
    /// LocalOutputSmokeTest's ToneGenerator for the same underlying
    /// reason.
    private final class PollState: @unchecked Sendable {
        let header: UnsafeMutablePointer<UInt32>
        let ringFloatsBase: UnsafeMutablePointer<Float>
        let ringBuffer: RingBuffer
        var lastReadIndex: UInt32
        var shouldStop = false
        // stop() must not munmap the pointers above while the poll
        // thread could still be mid-iteration using them (it only
        // checks shouldStop once per ~5ms loop, not instantly) — this
        // signals once pollLoop() has actually returned, and stop()
        // waits on it before unmapping. Caught on this same read-through,
        // not by any test: the window is small (<=5ms) and never
        // crashed during our testing, but it's a real use-after-unmap
        // race either way.
        let stoppedSignal = DispatchSemaphore(value: 0)

        init(header: UnsafeMutablePointer<UInt32>, ringFloatsBase: UnsafeMutablePointer<Float>, ringBuffer: RingBuffer, startIndex: UInt32) {
            self.header = header
            self.ringFloatsBase = ringFloatsBase
            self.ringBuffer = ringBuffer
            self.lastReadIndex = startIndex
        }

        func pollLoop() {
            defer { stoppedSignal.signal() }
            let capacity = Layout.capacityFrames
            let channels = Int(Layout.channelCount)
            var scratch = [Float](repeating: 0, count: 0)
            while !shouldStop {
                let currentWrite = header[1]
                var available = currentWrite &- lastReadIndex // unsigned wraparound-safe
                if available > capacity / 2 {
                    // Fell far behind (poll thread stalled, or the
                    // counter moved backwards after a driver reset, which
                    // wraps to a huge value). The writer may already be
                    // overwriting the oldest frames, so reading them would
                    // return torn audio — resync to "now" instead.
                    lastReadIndex = currentWrite
                    available = 0
                }
                if available > 0 {
                    let framesToRead = available
                    if scratch.count != Int(framesToRead) * channels {
                        scratch = [Float](repeating: 0, count: Int(framesToRead) * channels)
                    }
                    scratch.withUnsafeMutableBufferPointer { dest in
                        for i in 0..<Int(framesToRead) {
                            let srcFrame = Int((lastReadIndex &+ UInt32(i)) % capacity)
                            for ch in 0..<channels {
                                dest[i * channels + ch] = ringFloatsBase[srcFrame * channels + ch]
                            }
                        }
                    }
                    scratch.withUnsafeBufferPointer { ptr in
                        ringBuffer.write(ptr.baseAddress!, count: ptr.count)
                    }
                    lastReadIndex = lastReadIndex &+ framesToRead
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    private let outputRingBuffer: RingBuffer
    private var fileDescriptor: Int32 = -1
    private var mappedPointer: UnsafeMutableRawPointer?
    private var pollThread: Thread?
    private var pollState: PollState?

    public init(ringBuffer: RingBuffer, preset: VirtualDevicePreset = .main) {
        self.outputRingBuffer = ringBuffer
        self.preset = preset
    }

    public func start() throws {
        let fd = soundcast_shm_open_readonly(preset.shmName)
        guard fd >= 0 else { throw CaptureError.shmOpenFailed(errno) }
        fileDescriptor = fd

        guard let mapped = mmap(nil, Layout.totalSizeBytes, PROT_READ, MAP_SHARED, fd, 0),
              mapped != MAP_FAILED else {
            close(fd)
            fileDescriptor = -1
            throw CaptureError.mmapFailed(errno)
        }
        mappedPointer = mapped

        let header = mapped.assumingMemoryBound(to: UInt32.self)
        let actualCapacity = header[2]
        let actualChannels = header[3]
        let actualSampleRate = header[4]
        guard actualCapacity == Layout.capacityFrames,
              actualChannels == Layout.channelCount,
              actualSampleRate == Layout.sampleRateHz else {
            munmap(mapped, Layout.totalSizeBytes)
            mappedPointer = nil
            close(fd)
            fileDescriptor = -1
            throw CaptureError.headerValidationFailed(
                "expected capacity=\(Layout.capacityFrames) channels=\(Layout.channelCount) sampleRate=\(Layout.sampleRateHz), " +
                "got capacity=\(actualCapacity) channels=\(actualChannels) sampleRate=\(actualSampleRate)")
        }

        let ringFloatsBase = mapped.advanced(by: Layout.headerSizeBytes).assumingMemoryBound(to: Float.self)
        // Start from "now" — don't replay whatever was already sitting
        // in the ring from before this reader attached.
        let state = PollState(header: header, ringFloatsBase: ringFloatsBase, ringBuffer: outputRingBuffer, startIndex: header[1])
        pollState = state

        let thread = Thread { state.pollLoop() }
        thread.name = "com.soundcast.virtualdevicecapture.poll"
        thread.start()
        pollThread = thread
    }

    public func stop() {
        if let state = pollState {
            state.shouldStop = true
            // Wait for the poll thread to actually finish its current
            // iteration before unmapping — see stoppedSignal's comment.
            // Timeout is defensive only; the loop's own sleep is 5ms,
            // so this should return almost immediately in practice.
            _ = state.stoppedSignal.wait(timeout: .now() + 1.0)
        }
        pollState = nil
        pollThread = nil
        if let mapped = mappedPointer {
            munmap(mapped, Layout.totalSizeBytes)
            mappedPointer = nil
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}
