import Foundation
import SwiftUI
import SoundCastCore

/// Central observable state for the menu bar UI.
///
/// Design doc §7.3: supports true *simultaneous* multi-session casting —
/// the global tap ("cast everything") and each of the 5 static virtual
/// device slots are independent sources, each with its own on/off
/// state, device selection, and gains. This is the follow-up to the
/// earlier single-session version, which only let you pick one source
/// at a time; that was flagged there as an explicit scope gap, not
/// silently left as the final design.
@MainActor
final class AppState: ObservableObject {
    /// One thing the user can turn on/off independently. `.globalTap` is
    /// always available; `.virtualDevice` covers all 5 static slots
    /// (design doc §7.3) including the main "SoundCast" device.
    enum CastSource: Hashable {
        case globalTap
        case virtualDevice(VirtualDevicePreset)

        var displayName: String {
            switch self {
            case .globalTap: return "Cast Everything"
            case .virtualDevice(let preset): return preset.displayName
            }
        }
    }

    /// All sources the UI offers, in display order. Fixed list — the 5
    /// virtual device slots are a compile-time table on the driver side
    /// too (design doc §7.3), not something discovered at runtime.
    static let allSources: [CastSource] = [.globalTap] + VirtualDevicePreset.all.map { .virtualDevice($0) }

    /// Holds one source's running capture+output pair. Nothing here is
    /// `@Published` directly — `AppState` re-publishes the bits the UI
    /// needs (`activeSources`, per-source device/gain dictionaries) and
    /// this stays a plain bookkeeping value.
    private final class RunningSession {
        let ringBuffer: RingBuffer
        let capture: AudioCaptureSource
        let output: LocalOutputEngine

        init(ringBuffer: RingBuffer, capture: AudioCaptureSource, output: LocalOutputEngine) {
            self.ringBuffer = ringBuffer
            self.capture = capture
            self.output = output
        }

        func stop() {
            capture.stop()
            output.stop()
        }
    }

    @Published var activeSources: Set<CastSource> = []
    @Published var selectedDeviceIDsBySource: [CastSource: Set<String>] = [:]
    @Published var perDeviceGainBySource: [CastSource: [String: Float]] = [:]
    @Published var localDevices: [SoundDevice] = []
    @Published var airplayDevices: [SoundDevice] = []
    @Published var sonosDevices: [SoundDevice] = []
    /// Applies to every currently-active session — "master" meaning
    /// across everything playing, not per-source. Per-source balance is
    /// what the per-device sliders are for.
    @Published var masterVolume: Float = 1.0
    @Published var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled
    @Published var lastErrorBySource: [CastSource: String] = [:]

    private var runningSessions: [CastSource: RunningSession] = [:]

    func isActive(_ source: CastSource) -> Bool { activeSources.contains(source) }

    // MARK: - Helpers for the floating panel

    /// True while any source is on (including ones still waiting for the driver).
    var isCasting: Bool { !activeSources.isEmpty }

    /// What the panel's master switch turns back on after being switched off.
    private var resumeSources: Set<CastSource> = [.globalTap]

    /// The panel's single master switch: off stops every source (remembering
    /// which were on); on restores them, or "Cast Everything" the first time.
    func setCasting(_ on: Bool) {
        if on {
            guard !isCasting else { return }
            for source in Self.allSources where resumeSources.contains(source) {
                setActive(source, on: true)
            }
        } else {
            guard isCasting else { return }
            resumeSources = activeSources
            for source in Self.allSources where isActive(source) {
                setActive(source, on: false)
            }
        }
    }

    /// Devices ticked for one source, in list order.
    func selectedDevices(for source: CastSource) -> [SoundDevice] {
        let selected = selectedDeviceIDsBySource[source] ?? []
        return localDevices.filter { selected.contains($0.id) }
    }

    /// Every device currently receiving audio from any active source, de-duplicated.
    var activeDevices: [SoundDevice] {
        var seen = Set<String>()
        var result: [SoundDevice] = []
        for source in Self.allSources where isActive(source) {
            for device in selectedDevices(for: source) where seen.insert(device.id).inserted {
                result.append(device)
            }
        }
        return result
    }

    /// Active source names, in display order.
    var activeSourceNames: [String] {
        Self.allSources.filter { isActive($0) }.map(\.displayName)
    }

    func refreshDeviceList() {
        localDevices = LocalDeviceEnumerator.listOutputDevices()
        for source in Self.allSources {
            for device in localDevices where perDeviceGainBySource[source]?[device.id] == nil {
                perDeviceGainBySource[source, default: [:]][device.id] = 1.0
            }
        }
    }

    var groupedDevices: [(SoundDevice.Category, [SoundDevice])] {
        let all = localDevices + airplayDevices + sonosDevices
        let grouped = Dictionary(grouping: all, by: \.category)
        return SoundDevice.Category.allCases
            .sorted()
            .map { ($0, grouped[$0] ?? []) }
    }

    func toggleDevice(_ device: SoundDevice, for source: CastSource) {
        var selected = selectedDeviceIDsBySource[source, default: []]
        if selected.contains(device.id) {
            selected.remove(device.id)
        } else {
            selected.insert(device.id)
        }
        selectedDeviceIDsBySource[source] = selected
        if isActive(source) {
            applySelectionToRunningOutput(for: source)
        }
    }

    func setGain(for device: SoundDevice, source: CastSource, gain: Float) {
        perDeviceGainBySource[source, default: [:]][device.id] = gain
        runningSessions[source]?.output.setGain(deviceID: device.id, gain: gain)
    }

    func setMasterVolume(_ volume: Float) {
        masterVolume = volume
        for session in runningSessions.values {
            session.output.masterGain = volume
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    /// Start or stop one specific source — independent of every other
    /// source's state, so e.g. "Cast Everything" and
    /// "SoundCast - Preset 1" can both be on at once, each with their
    /// own ticked devices.
    func setActive(_ source: CastSource, on: Bool) {
        guard isActive(source) != on else { return }
        if on {
            startSession(source)
        } else {
            stopSession(source)
        }
    }

    private enum StartOutcome { case started, waitingForDriver, failed }

    /// Virtual-device sources whose shared buffer doesn't exist yet (the
    /// driver creates it on first use) are retried once a second until it
    /// appears, the user switches the source off, or a different error hits.
    private var retryTasks: [CastSource: Task<Void, Never>] = [:]

    private func startSession(_ source: CastSource) {
        switch attemptStart(source) {
        case .started, .failed:
            break
        case .waitingForDriver:
            // Show it as on ("armed") so the toggle reflects the user's intent.
            activeSources.insert(source)
            lastErrorBySource[source] = "Waiting for audio to be played to \"\(source.displayName)\"…"
            retryTasks[source] = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    switch self.attemptStart(source) {
                    case .waitingForDriver:
                        continue
                    case .started:
                        self.retryTasks[source] = nil
                        return
                    case .failed:
                        self.retryTasks[source] = nil
                        self.activeSources.remove(source)
                        return
                    }
                }
            }
        }
    }

    private func attemptStart(_ source: CastSource) -> StartOutcome {
        // ~2s of 48kHz stereo float32 — generous headroom for the
        // capture-to-render handoff; Phase 2/3 consumers (AirPlay
        // senders, Sonos stream) get their own, separately-sized ring
        // buffers fed from the same capture callback, per design doc §6.
        let buffer = RingBuffer(capacitySamples: 48_000 * 2 * 2)

        let captureEngine: AudioCaptureSource = switch source {
        case .globalTap: ProcessTapCapture(ringBuffer: buffer)
        case .virtualDevice(let preset): VirtualDeviceCapture(ringBuffer: buffer, preset: preset)
        }
        let outputEngine = LocalOutputEngine(sourceRingBuffer: buffer)
        outputEngine.masterGain = masterVolume

        do {
            try captureEngine.start()
            try applySelection(on: outputEngine, for: source)
            runningSessions[source] = RunningSession(ringBuffer: buffer, capture: captureEngine, output: outputEngine)
            activeSources.insert(source)
            lastErrorBySource[source] = nil
            return .started
        } catch {
            captureEngine.stop()
            outputEngine.stop()
            if case .virtualDevice = source,
               case VirtualDeviceCapture.CaptureError.shmOpenFailed(let code) = error,
               code == ENOENT {
                return .waitingForDriver
            }
            lastErrorBySource[source] = "Failed to start: \(error)"
            NSLog("[SoundCast][AppState] startSession(\(source.displayName)) failed: \(error)")
            return .failed
        }
    }

    private func stopSession(_ source: CastSource) {
        retryTasks[source]?.cancel()
        retryTasks[source] = nil
        lastErrorBySource[source] = nil
        runningSessions[source]?.stop()
        runningSessions[source] = nil
        activeSources.remove(source)
    }

    private func applySelectionToRunningOutput(for source: CastSource) {
        guard let session = runningSessions[source] else { return }
        do {
            try applySelection(on: session.output, for: source)
        } catch {
            lastErrorBySource[source] = "Failed to update outputs: \(error)"
            NSLog("[SoundCast][AppState] applySelectionToRunningOutput(\(source.displayName)) failed: \(error)")
        }
    }

    private func applySelection(on outputEngine: LocalOutputEngine, for source: CastSource) throws {
        let selected = selectedDeviceIDsBySource[source] ?? []
        let gains = perDeviceGainBySource[source] ?? [:]
        let targets = localDevices
            .filter { selected.contains($0.id) }
            .map { LocalOutputEngine.Target(device: $0, gain: gains[$0.id] ?? 1.0) }
        guard !targets.isEmpty else {
            outputEngine.stop()
            return
        }
        try outputEngine.reconfigure(targets: targets)
    }
}
