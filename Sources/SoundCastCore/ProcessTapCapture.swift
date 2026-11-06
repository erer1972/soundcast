import AudioToolbox
import CoreAudio
import Foundation

/// Global system-audio capture via Core Audio's process-tap API
/// (design doc §2). Public API since macOS 14.2, documented by Apple
/// ("Capturing system audio with Core Audio taps" / the AudioCap sample).
///
/// ⚠️ Honesty note: this file has not been built or run — there is no
/// macOS compiler available in the environment this was written in.
/// The high-level flow (CATapDescription → AudioHardwareCreateProcessTap
/// → wrap in a private aggregate device → read via an IOProc) matches
/// Apple's documented approach, but exact constant names
/// (`kAudioSubTapUIDKey` and friends) and `CATapDescription`'s Swift
/// initializer labels are reconstructed from memory of the public docs,
/// not verified against a compiler. Treat the first `swift build` on
/// your Mac as the real check of this file — symbol-name mismatches here
/// are the most likely first build errors, and are normal to fix once
/// the compiler names the actual problem.
@available(macOS 14.2, *)
public final class ProcessTapCapture {

    private(set) public var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private(set) public var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let outputRingBuffer: RingBuffer

    public init(ringBuffer: RingBuffer) {
        self.outputRingBuffer = ringBuffer
    }

    public enum CaptureError: Error {
        case failedToResolveOwnProcessObject(OSStatus)
        case failedToCreateTap(OSStatus)
        case failedToCreateAggregateDevice(OSStatus)
        case failedToStartIO(OSStatus)
    }

    /// Starts a global tap capturing every process's audio except our
    /// own (so we never feed our own output back into the loop), muting
    /// the tap's contribution to the real output devices while active
    /// (design doc §2 step 4) unless the user has also ticked "This
    /// Mac's speakers" as a cast target — in which case LocalOutputEngine
    /// is responsible for including that device as one of its own render
    /// targets, not this tap.
    public func start() throws {
        let ownProcessObjectID = try resolveOwnProcessObjectID()

        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ownProcessObjectID]
        )
        tapDescription.name = "SoundCast Global Tap"
        tapDescription.isPrivate = true
        // Mute the original output path while this tap is active, so
        // audio isn't doubled on the device(s) it was originally headed
        // to. LocalOutputEngine re-adds "This Mac" explicitly if ticked.
        tapDescription.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let createTapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard createTapStatus == noErr else {
            throw CaptureError.failedToCreateTap(createTapStatus)
        }
        tapObjectID = newTapID

        guard let tapUID = stringProperty(newTapID, selector: kAudioTapPropertyUID) else {
            throw CaptureError.failedToCreateTap(-1)
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SoundCast-Internal-Capture",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let createAggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard createAggStatus == noErr else {
            throw CaptureError.failedToCreateAggregateDevice(createAggStatus)
        }
        aggregateDeviceID = newAggregateID

        try startIOProc(on: newAggregateID)
    }

    public func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }
    }

    // MARK: - IOProc: pushes captured frames into the shared ring buffer

    private func startIOProc(on deviceID: AudioObjectID) throws {
        let ringBuffer = outputRingBuffer
        var newProcID: AudioDeviceIOProcID?

        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, deviceID, nil
        ) { _, inputData, _, _, _ in
            // Same fix as LocalOutputEngine's IOProc: use the overlay
            // type that correctly walks AudioBufferList's real
            // variable-length buffer array, instead of copying the
            // struct by value and reading past the copy's bounds.
            // There's no separate read-only overlay type — bridge
            // through `mutating:` and only read from it below.
            let bufferList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                data.withMemoryRebound(to: Float.self, capacity: frameCount) { floatPtr in
                    ringBuffer.write(floatPtr, count: frameCount)
                }
            }
        }
        guard createStatus == noErr, let procID = newProcID else {
            throw CaptureError.failedToStartIO(createStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            throw CaptureError.failedToStartIO(startStatus)
        }
    }

    // MARK: - Helpers

    private func resolveOwnProcessObjectID() throws -> AudioObjectID {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var outSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid,
            &outSize, &objectID
        )
        guard status == noErr else {
            throw CaptureError.failedToResolveOwnProcessObject(status)
        }
        return objectID
    }

    private func stringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfValue: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfValue) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cfValue as String
    }
}
