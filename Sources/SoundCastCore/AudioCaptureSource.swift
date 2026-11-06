import Foundation

/// Common shape shared by the two capture sources (design doc §7(c)):
/// `ProcessTapCapture` ("cast everything," the global process tap) and
/// `VirtualDeviceCapture` (per-app, via the "SoundCast" system-wide
/// output device). Lets `AppState` hold one active capture source
/// without caring which kind it is.
public protocol AudioCaptureSource: AnyObject {
    func start() throws
    func stop()
}

extension ProcessTapCapture: AudioCaptureSource {}
extension VirtualDeviceCapture: AudioCaptureSource {}
