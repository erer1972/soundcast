import AVFoundation
import Foundation
import SoundCastCore

/// Measures how long after capture a set of outputs is actually heard:
/// plays a few clicks through the system output (the SoundCast device),
/// timestamps them as they enter the source ring, and timestamps them again
/// as the Mac's microphone hears them. AppState runs it twice (local
/// speakers only, then AirPlay rooms only) and applies the difference.
@MainActor
final class SyncCalibrator {
    enum CalibrationError: Error, CustomStringConvertible {
        case microphoneDenied
        case engine(String)
        case notHeard(captured: Int, heard: Int)
        case inconsistent(spreadMilliseconds: Int)
        case implausible(differenceMilliseconds: Int)

        var description: String {
            switch self {
            case .microphoneDenied:
                return "microphone access is off (System Settings → Privacy & Security → Microphone → SoundCast)"
            case .engine(let reason):
                return "audio engine: \(reason)"
            case .notHeard(let captured, let heard):
                return "the microphone heard \(heard) of \(captured) clicks — turn the volume up, move the Mac closer, or reduce background noise"
            case .inconsistent(let spread):
                return "the clicks didn't line up (\(spread) ms apart) — probably background noise or an echo; try again in a quieter moment"
            case .implausible(let difference):
                return "measured \(difference) ms between the rooms, which doesn't look right — nothing was changed; try again"
            }
        }
    }

    private static let clickCount = 4
    private static let clickSpacing = 1.5
    private static let firstClickAt = 0.5

    private let ring: RingBuffer

    init(ring: RingBuffer) { self.ring = ring }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Median seconds from a click entering SoundCast to the microphone
    /// hearing it.
    func measure() async throws -> Double {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw CalibrationError.engine("no microphone input")
        }
        let recorder = MicRecorder(sampleRate: micFormat.sampleRate)
        // The tap block runs on an audio thread; it must not be main-actor
        // isolated (Swift traps on the isolation check), so it comes from
        // the nonisolated recorder.
        input.installTap(onBus: 0, bufferSize: 1024, format: micFormat, block: recorder.tapBlock())

        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let clickFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let clicks = Self.makeClickTrain(format: clickFormat) else {
            throw CalibrationError.engine("could not make the click sound")
        }
        engine.connect(player, to: engine.mainMixerNode, format: clickFormat)

        do { try engine.start() } catch { throw CalibrationError.engine("\(error)") }
        defer {
            input.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            _ = ring.stopOnsetDetection()
        }

        try await Task.sleep(nanoseconds: 600_000_000)   // background noise sample
        ring.startOnsetDetection(threshold: 0.05)
        player.scheduleBuffer(clicks, completionHandler: nil)
        player.play()
        let lastClick = Self.firstClickAt + Double(Self.clickCount - 1) * Self.clickSpacing
        try await Task.sleep(nanoseconds: UInt64((lastClick + 4.0) * 1_000_000_000))

        let captured = ring.stopOnsetDetection().map { AVAudioTime.seconds(forHostTime: $0) }
        let heard = recorder.onsets()
        NSLog("[SoundCast][Calibrate] captured \(captured.count) click(s), heard \(heard.count) onset(s)")

        // Pair in order: each captured click with the first heard onset
        // after it (and after the previous pair's).
        var delays: [Double] = []
        var next = 0
        for click in captured {
            while next < heard.count, heard[next] < click { next += 1 }
            guard next < heard.count else { break }
            let delay = heard[next] - click
            if delay < 4 { delays.append(delay) }
            next += 1
        }
        guard delays.count >= 3 else {
            throw CalibrationError.notHeard(captured: captured.count, heard: delays.count)
        }
        delays.sort()
        NSLog("[SoundCast][Calibrate] delays \(delays.map { String(format: "%.3f", $0) })")
        // Real clicks through one path agree within a few ms; a wide spread
        // means some "onsets" were noise or another room's echo.
        let spread = delays.last! - delays.first!
        guard spread < 0.06 else { throw CalibrationError.inconsistent(spreadMilliseconds: Int(spread * 1000)) }
        return delays[delays.count / 2]
    }

    /// Short full-scale noise bursts (sharp onsets the mic can't miss).
    private static func makeClickTrain(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = firstClickAt + Double(clickCount - 1) * clickSpacing + 0.5
        let frames = AVAudioFrameCount(total * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(frames))
        }
        let burst = Int(0.006 * rate)
        var seed: UInt32 = 12_345
        for click in 0..<clickCount {
            let start = Int((firstClickAt + Double(click) * clickSpacing) * rate)
            for i in 0..<burst {
                seed = seed &* 1_103_515_245 &+ 12_345
                let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
                let fade = Float(burst - i) / Float(burst)
                for channel in 0..<Int(format.channelCount) {
                    channels[channel][start + i] = noise * fade
                }
            }
        }
        return buffer
    }
}

/// Collects microphone samples with host timestamps (filled on the audio
/// thread, analysed afterwards on the main actor).
private final class MicRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate: Double
    private var chunks: [(start: Double, samples: [Float])] = []

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    nonisolated func tapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, time in append(buffer, at: time) }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let data = buffer.floatChannelData, time.isHostTimeValid else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        let start = AVAudioTime.seconds(forHostTime: time.hostTime)
        lock.lock()
        chunks.append((start, samples))
        lock.unlock()
    }

    /// Host-time seconds of each sharp rise well above the background.
    func onsets() -> [Double] {
        lock.lock()
        let chunks = self.chunks
        lock.unlock()
        // Background level: the quietest chunks (the start is before any click).
        let levels = chunks.map { chunk in chunk.samples.reduce(Float(0)) { max($0, abs($1)) } }.sorted()
        let floor = levels.isEmpty ? 0 : levels[levels.count / 4]
        let threshold = max(floor * 6, 0.01)
        var result: [Double] = []
        var last = -Double.infinity
        for chunk in chunks {
            for (index, sample) in chunk.samples.enumerated() where abs(sample) > threshold {
                let time = chunk.start + Double(index) / sampleRate
                if time - last > 0.5 {
                    result.append(time)
                    last = time
                }
            }
        }
        return result
    }
}
