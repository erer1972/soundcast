import Combine
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

    /// One AirPlay receiver being fed by one source: its own mirror of
    /// that source's capture buffer, plus the sender (nil while the
    /// session is still being resolved/negotiated).
    private final class AirPlayCast {
        let mirror: RingBuffer
        var sender: AirPlayRealtimeSender?
        var startTask: Task<Void, Never>?
        init(mirror: RingBuffer) { self.mirror = mirror }
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
    /// Per AirPlay device: "Connecting…", "Playing", or an error message.
    @Published var airplayStatus: [String: String] = [:]

    private var runningSessions: [CastSource: RunningSession] = [:]
    private var airplayCasts: [CastSource: [String: AirPlayCast]] = [:]
    /// Bonjour instance name per AirPlay device ID, for resolving.
    private var airplayServiceNames: [String: String] = [:]
    /// One PTP grandmaster for every AirPlay session (UDP 319/320 can
    /// only be bound once). Created on first use, stopped when idle.
    private var ptpClock: AirPlayPTPClock?
    private let airplayIdentity = AirPlayIdentity.loadOrCreate()

    // Design doc §12 Phase 2 step 1: Bonjour discovery feeds `airplayDevices`
    // (already-existing published property, previously always empty) so
    // found rooms show up in the same grouped device list the UI already
    // renders. Not yet wired to actual output — see DeviceRow's
    // `isInteractive` check in MenuBarContentView.swift.
    private let airPlayDiscovery = AirPlayDiscovery()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        airPlayDiscovery.$receivers
            .sink { [weak self] receivers in
                for receiver in receivers {
                    self?.airplayServiceNames["airplay:\(receiver.id)"] = receiver.name
                }
                self?.airplayDevices = receivers.map { receiver in
                    SoundDevice(
                        id: "airplay:\(receiver.id)",
                        name: receiver.name,
                        category: .airplay,
                        audioObjectID: nil
                    )
                }
            }
            .store(in: &cancellables)
        airPlayDiscovery.start()
        setUpLaunchArgumentCasting()
    }

    /// Test hook for driving the app headless (e.g. over ssh):
    /// `open SoundCast.app --args --cast-airplay kaan` turns on "Cast
    /// Everything" and ticks that AirPlay room as soon as Bonjour finds it.
    private func setUpLaunchArgumentCasting() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--cast-airplay"), flag + 1 < arguments.count else { return }
        let roomName = arguments[flag + 1]
        NSLog("[SoundCast][AppState] --cast-airplay: waiting for \"\(roomName)\"")
        $airplayDevices
            .compactMap { $0.first { $0.name == roomName } }
            .first()
            .sink { [weak self] device in
                guard let self else { return }
                NSLog("[SoundCast][AppState] --cast-airplay: casting everything to \"\(roomName)\"")
                if self.selectedDeviceIDsBySource[.globalTap]?.contains(device.id) != true {
                    self.toggleDevice(device, for: .globalTap)
                }
                self.setActive(.globalTap, on: true)
            }
            .store(in: &cancellables)
    }

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
        return (localDevices + airplayDevices).filter { selected.contains($0.id) }
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
            // A receiver plays one sender at a time; a second session from
            // another source would just kick the first one off.
            if device.category == .airplay,
               let other = Self.allSources.first(where: { $0 != source && selectedDeviceIDsBySource[$0]?.contains(device.id) == true }) {
                lastErrorBySource[source] = "\(device.name) is already used by \"\(other.displayName)\"."
                return
            }
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
        airplayCasts[source]?[device.id]?.sender?.setVolume(gain * masterVolume)
    }

    func setMasterVolume(_ volume: Float) {
        masterVolume = volume
        for session in runningSessions.values {
            session.output.masterGain = volume
        }
        for (source, casts) in airplayCasts {
            for (deviceID, cast) in casts {
                cast.sender?.setVolume((perDeviceGainBySource[source]?[deviceID] ?? 1.0) * volume)
            }
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
            runningSessions[source] = RunningSession(ringBuffer: buffer, capture: captureEngine, output: outputEngine)
            do {
                try applySelection(on: outputEngine, for: source)
            } catch {
                for deviceID in Array(airplayCasts[source]?.keys ?? [:].keys) {
                    stopAirPlay(deviceID: deviceID, source: source)
                }
                runningSessions[source] = nil
                throw error
            }
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
        for deviceID in Array(airplayCasts[source]?.keys ?? [:].keys) {
            stopAirPlay(deviceID: deviceID, source: source)
        }
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
        syncAirPlay(for: source, selected: selected)
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

    // MARK: - AirPlay

    /// Starts senders for newly ticked AirPlay devices and stops ones that
    /// were unticked. Only runs while the source's capture is running.
    private func syncAirPlay(for source: CastSource, selected: Set<String>) {
        let wanted = Set(selected.filter { $0.hasPrefix("airplay:") })
        let current = Set(airplayCasts[source]?.keys ?? [:].keys)
        for deviceID in current.subtracting(wanted) {
            stopAirPlay(deviceID: deviceID, source: source)
        }
        for deviceID in wanted.subtracting(current) {
            startAirPlay(deviceID: deviceID, source: source)
        }
    }

    private func startAirPlay(deviceID: String, source: CastSource) {
        guard let session = runningSessions[source] else { return }
        guard let serviceName = airplayServiceNames[deviceID] else {
            airplayStatus[deviceID] = "Not found on the network"
            return
        }
        // ~2 s of capture-rate stereo; the sender keeps ~60 ms in it.
        let mirror = RingBuffer(capacitySamples: Int(session.capture.sampleRate) * 2 * 2)
        let cast = AirPlayCast(mirror: mirror)
        airplayCasts[source, default: [:]][deviceID] = cast
        airplayStatus[deviceID] = "Connecting…"
        let inputRate = session.capture.sampleRate
        let volume = (perDeviceGainBySource[source]?[deviceID] ?? 1.0) * masterVolume

        cast.startTask = Task { [weak self] in
            do {
                let receiver = try await AirPlayReceiverResolver.resolve(serviceName: serviceName)
                guard let self, !Task.isCancelled else { return }
                let clock = try self.sharedPTPClock(firstPeerIPv4: receiver.ipv4)
                let sender = AirPlayRealtimeSender(
                    receiver: receiver, identity: self.airplayIdentity, ptpClock: clock,
                    source: mirror, inputSampleRate: inputRate
                )
                sender.setVolume(volume)
                sender.onFailure = { [weak self] error in
                    Task { @MainActor in self?.airPlayFailed(deviceID: deviceID, source: source, error: error) }
                }
                session.ringBuffer.addMirror(mirror)
                cast.sender = sender
                try await sender.start()
                guard !Task.isCancelled else {
                    await sender.stop()
                    return
                }
                self.airplayStatus[deviceID] = "Playing"
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.airPlayFailed(deviceID: deviceID, source: source, error: error)
            }
        }
    }

    private func stopAirPlay(deviceID: String, source: CastSource) {
        guard let cast = airplayCasts[source]?.removeValue(forKey: deviceID) else { return }
        cast.startTask?.cancel()
        runningSessions[source]?.ringBuffer.removeMirror(cast.mirror)
        airplayStatus[deviceID] = nil
        let startTask = cast.startTask
        Task { [weak self] in
            // Let an in-flight start settle before tearing down, so stop
            // never races establishSession on the same RTSP connection.
            await startTask?.value
            await cast.sender?.stop()
            self?.stopPTPClockIfIdle()
        }
    }

    private func airPlayFailed(deviceID: String, source: CastSource, error: Error) {
        NSLog("[SoundCast][AppState] AirPlay \(deviceID) failed: \(error)")
        let message: String
        if case AirPlayRealtimeSender.SenderError.notPaired = error {
            message = "Not paired with SoundCast yet"
        } else {
            message = "Failed: \(error)"
        }
        stopAirPlay(deviceID: deviceID, source: source)
        airplayStatus[deviceID] = message
    }

    /// Clean shutdown for app quit: TEARDOWN every AirPlay session (in
    /// parallel, each capped at 2 s by the sender), then stop capture so
    /// the tap stops muting the Mac's own output.
    func shutdown() async {
        let casts = airplayCasts.flatMap { source, casts in casts.values.map { (source, $0) } }
        airplayCasts.removeAll()
        for (source, cast) in casts {
            cast.startTask?.cancel()
            runningSessions[source]?.ringBuffer.removeMirror(cast.mirror)
        }
        NSLog("[SoundCast][AppState] shutdown: tearing down \(casts.count) AirPlay session(s)")
        // One task per session so the TEARDOWNs run concurrently.
        let stops = casts.map { _, cast in
            let startTask = cast.startTask
            return Task { @MainActor in
                await startTask?.value
                await cast.sender?.stop()
            }
        }
        for stop in stops { await stop.value }
        for source in Self.allSources where isActive(source) {
            stopSession(source)
        }
        ptpClock?.stop()
        ptpClock = nil
        NSLog("[SoundCast][AppState] shutdown: done")
    }

    private func sharedPTPClock(firstPeerIPv4: String) throws -> AirPlayPTPClock {
        if let ptpClock { return ptpClock }
        let clock = try AirPlayPTPClock(peerIPv4: firstPeerIPv4)
        clock.removePeer(ipv4: firstPeerIPv4) // senders add/remove their own peer
        clock.start()
        ptpClock = clock
        return clock
    }

    private func stopPTPClockIfIdle() {
        guard airplayCasts.values.allSatisfy({ $0.isEmpty }), let clock = ptpClock, clock.peerCount == 0 else { return }
        clock.stop()
        ptpClock = nil
    }
}
