import CoreAudio
import Foundation

/// A device the user can tick in the menu bar list. Local Core Audio
/// devices populate `.thisMac` and `.bluetooth`/`.other`; Bonjour populates
/// `.airplay`. Sonos-specific discovery remains future work.
public struct SoundDevice: Identifiable, Hashable {
    public enum Category: String, CaseIterable, Comparable {
        case thisMac = "This Mac"
        case bluetooth = "Bluetooth"
        case airplay = "AirPlay"
        case sonos = "Sonos"

        /// Fixed display order, not alphabetical.
        private var sortIndex: Int {
            switch self {
            case .thisMac: return 0
            case .bluetooth: return 1
            case .airplay: return 2
            case .sonos: return 3
            }
        }
        public static func < (lhs: Category, rhs: Category) -> Bool {
            lhs.sortIndex < rhs.sortIndex
        }
    }

    public let id: String // Core Audio device UID, or a synthetic ID for Phase 2/3 network devices
    public let name: String
    public let category: Category
    /// Core Audio AudioObjectID, for real local devices only.
    public let audioObjectID: AudioObjectID?

    public init(id: String, name: String, category: Category, audioObjectID: AudioObjectID?) {
        self.id = id
        self.name = name
        self.category = category
        self.audioObjectID = audioObjectID
    }
}

/// Enumerates real Core Audio output devices on this Mac and buckets them
/// into "This Mac" (built-in / wired / USB / other non-Bluetooth) vs
/// "Bluetooth", using CoreAudio's own transport-type property rather than
/// name-sniffing.
public enum LocalDeviceEnumerator {

    public static func listOutputDevices() -> [SoundDevice] {
        guard let ids = allDeviceIDs() else { return [] }
        return ids.compactMap { deviceID -> SoundDevice? in
            guard hasOutputStreams(deviceID) else { return nil }
            guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            guard let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) else { return nil }
            // Don't list our own private aggregate devices (Phase 1
            // capture/output plumbing) back to the user as selectable
            // outputs — they're prefixed distinctly so we can filter them.
            if name.hasPrefix("SoundCast-Internal-") { return nil }
            // Core Audio's own temporary aggregates (e.g. while an app uses
            // the microphone through AVAudioEngine) aren't real outputs.
            if name.hasPrefix("CADefaultDeviceAggregate") { return nil }
            // Likewise never offer our own virtual HAL devices as render
            // targets: audio sent to them is read straight back by
            // VirtualDeviceCapture, which would be a feedback loop (and
            // the smoke tools' "render to everything" default hit it).
            if uid.hasPrefix("com.soundcast.device") { return nil }
            let transport = transportType(deviceID)
            let category: SoundDevice.Category = (transport == kAudioDeviceTransportTypeBluetooth)
                ? .bluetooth
                : .thisMac
            return SoundDevice(id: uid, name: name, category: category, audioObjectID: deviceID)
        }
    }

    // MARK: - Core Audio property plumbing

    private static func allDeviceIDs() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
        guard status == noErr else { return nil }
        return ids
    }

    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private static func transportType(_ deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    private static func stringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfValue: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfValue) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cfValue as String
    }
}

/// Reads and changes the Mac's default output device (what the Sound menu
/// selects), by device UID.
public enum SystemOutputDevice {
    public static func currentUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
              let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }

    /// Returns false if no device has that UID (e.g. a Bluetooth speaker
    /// that has since disconnected) or Core Audio refused the change.
    @discardableResult
    public static func select(uid: String) -> Bool {
        var translate = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &translate,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &deviceID
        ) == noErr
    }
}
