import Foundation

/// Describes one of the static virtual-device slots (now just "SoundCast")
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

    public static let all: [VirtualDevicePreset] = [.main]
}
