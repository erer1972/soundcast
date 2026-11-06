import Foundation

/// Describes one of the 5 static virtual-device slots
/// `HALPlugin/src/driver.c` publishes (design doc §7.3: a fixed table
/// of room-preset devices, chosen over dynamic CreateDevice/DestroyDevice
/// given how much iteration even the single main device needed).
///
/// ⚠️ Must stay in exact sync with driver.c's `gDeviceSlots` table — the
/// `deviceUID` and `shmName` values here have to match the corresponding
/// slot's `uid`/`shmName` fields there exactly, or `VirtualDeviceCapture`
/// will either fail to find the device at all (wrong UID) or fail
/// header validation (wrong shm name pointing at a different slot's
/// segment, or none at all).
public struct VirtualDevicePreset: Hashable, Sendable {
    public let displayName: String
    public let deviceUID: String
    public let shmName: String

    public static let main = VirtualDevicePreset(
        displayName: "SoundCast", deviceUID: "com.soundcast.device", shmName: "/soundcast_output_v1")
    public static let preset1 = VirtualDevicePreset(
        displayName: "SoundCast - Preset 1", deviceUID: "com.soundcast.device.preset1", shmName: "/soundcast_output_preset1")
    public static let preset2 = VirtualDevicePreset(
        displayName: "SoundCast - Preset 2", deviceUID: "com.soundcast.device.preset2", shmName: "/soundcast_output_preset2")
    public static let preset3 = VirtualDevicePreset(
        displayName: "SoundCast - Preset 3", deviceUID: "com.soundcast.device.preset3", shmName: "/soundcast_output_preset3")
    public static let preset4 = VirtualDevicePreset(
        displayName: "SoundCast - Preset 4", deviceUID: "com.soundcast.device.preset4", shmName: "/soundcast_output_preset4")

    public static let all: [VirtualDevicePreset] = [.main, .preset1, .preset2, .preset3, .preset4]
}
