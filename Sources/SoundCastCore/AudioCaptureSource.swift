import Foundation

/// Common shape shared by the two capture sources (design doc §7(c)):
/// `ProcessTapCapture` ("cast everything," the global process tap) and
/// `VirtualDeviceCapture` (per-app, via the "SoundCast" system-wide
/// output device). Lets `AppState` hold one active capture source
/// without caring which kind it is.
public protocol AudioCaptureSource: AnyObject {
    func start() throws
    func stop()
    /// Sample rate of the interleaved stereo Float32 written to the ring
    /// buffer. Valid after `start()`; AirPlay senders resample from it.
    var sampleRate: Double { get }
}

extension ProcessTapCapture: AudioCaptureSource {}
extension VirtualDeviceCapture: AudioCaptureSource {
    public var sampleRate: Double { Double(Layout.sampleRateHz) }
}
