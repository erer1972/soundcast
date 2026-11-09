import Combine
import Foundation
import Network
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

    /// One Sonos S1 receiver attached to a running capture source.
    private final class SonosCast {
        let streamer: SonosAudioStreamer
        var startTask: Task<Void, Never>?
        init(streamer: SonosAudioStreamer) { self.streamer = streamer }
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
    @Published var sonosStatus: [String: String] = [:]
    /// AirPlay devices that failed pair-verify (show a "Pair…" button).
    @Published var unpairedAirPlayDevices: Set<String> = []

    enum PairingStep: Equatable {
        case requestingPIN
        case waitingForPIN
        case verifying
        case failed(String)
    }
    /// The one pairing in progress (device ID and step), if any.
    @Published var pairing: (deviceID: String, step: PairingStep)?
    private var pairingConnection: AirPlayRTSPConnection?
    private var reconnectAttempts: [String: Int] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]

    private var runningSessions: [CastSource: RunningSession] = [:]
    private var airplayCasts: [CastSource: [String: AirPlayCast]] = [:]
    private var sonosCasts: [CastSource: [String: SonosCast]] = [:]
    private var sonosVolumeTasks: [String: Task<Void, Never>] = [:]
    private var sonosVolumeGeneration: [String: Int] = [:]
    private var sonosStopTasks: [String: Task<Void, Never>] = [:]
    private var sonosStopGeneration: [String: UUID] = [:]
    /// Bonjour instance name per AirPlay device ID, for resolving.
    private var airplayServiceNames: [String: String] = [:]
    private var sonosReceiversByDeviceID: [String: SonosReceiver] = [:]
    /// One PTP grandmaster for every AirPlay session (UDP 319/320 can
    /// only be bound once). Created on first use, stopped when idle.
    private var ptpClock: AirPlayPTPClock?
    private let airplayIdentity = AirPlayIdentity.loadOrCreate()

    // Bonjour discovery feeds the grouped network-device lists.
    private let airPlayDiscovery = AirPlayDiscovery()
    private let sonosDiscovery = SonosDiscovery()
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
        sonosDiscovery.$receivers
            .sink { [weak self] receivers in
                guard let self else { return }
                self.sonosReceiversByDeviceID = Dictionary(uniqueKeysWithValues: receivers.map { ("sonos:\($0.id)", $0) })
                self.sonosDevices = receivers.map { receiver in
                    SoundDevice(
                        id: "sonos:\(receiver.id)",
                        name: receiver.name,
                        category: .sonos,
                        audioObjectID: nil
                    )
                }
                for receiver in receivers {
                    let deviceID = "sonos:\(receiver.id)"
                    Task { [weak self] in
                        guard let self, let volume = try? await SonosUPnPClient.getVolume(for: receiver),
                              self.sonosReceiversByDeviceID[deviceID]?.id == receiver.id else { return }
                        for source in Self.allSources where self.perDeviceGainBySource[source]?[deviceID] == nil {
                            self.perDeviceGainBySource[source, default: [:]][deviceID] = Float(volume) / 100
                        }
                    }
                }
            }
            .store(in: &cancellables)
        airPlayDiscovery.start()
        sonosDiscovery.start()
        setUpLaunchArgumentCasting()
    }

    /// Test hook for driving the app headless (e.g. over ssh):
    /// Repeated `--cast-airplay <name>` arguments turn on "Cast Everything"
    /// and tick those rooms once Bonjour has found all of them.
    private func setUpLaunchArgumentCasting() {
        let arguments = CommandLine.arguments
        var airPlayRoomNames = Set<String>()
        var sonosRoomNames = Set<String>()
        var index = 0
        while index + 1 < arguments.count {
            if arguments[index] == "--cast-airplay" {
                airPlayRoomNames.insert(arguments[index + 1])
                index += 2
            } else if arguments[index] == "--cast-sonos" {
                sonosRoomNames.insert(arguments[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        if !airPlayRoomNames.isEmpty {
            let roomNameList = airPlayRoomNames.sorted().joined(separator: ", ")
            NSLog("[SoundCast][AppState] --cast-airplay: waiting for \"\(roomNameList)\"")
            $airplayDevices
                .compactMap { devices -> [SoundDevice]? in
                    let matching = devices.filter { airPlayRoomNames.contains($0.name) }
                    return Set(matching.map(\.name)) == airPlayRoomNames ? matching : nil
                }
                .first()
                .sink { [weak self] devices in
                    guard let self else { return }
                    NSLog("[SoundCast][AppState] --cast-airplay: casting everything to \"\(roomNameList)\"")
                    for device in devices where self.selectedDeviceIDsBySource[.globalTap]?.contains(device.id) != true {
                        self.toggleDevice(device, for: .globalTap)
                    }
                    self.setActive(.globalTap, on: true)
                }
                .store(in: &cancellables)
        }
        if !sonosRoomNames.isEmpty {
            let roomNameList = sonosRoomNames.sorted().joined(separator: ", ")
            let source = CastSource.virtualDevice(.main)
            NSLog("[SoundCast][AppState] --cast-sonos: waiting for \"\(roomNameList)\"")
            $sonosDevices
                .compactMap { devices -> [SoundDevice]? in
                    let matching = devices.filter { sonosRoomNames.contains($0.name) }
                    return Set(matching.map(\.name)) == sonosRoomNames ? matching : nil
                }
                .first()
                .sink { [weak self] devices in
                    guard let self else { return }
                    NSLog("[SoundCast][AppState] --cast-sonos: casting SoundCast virtual audio to \"\(roomNameList)\"")
                    for device in devices where self.selectedDeviceIDsBySource[source]?.contains(device.id) != true {
                        self.toggleDevice(device, for: source)
                    }
                    self.setActive(source, on: true)
                }
                .store(in: &cancellables)
        }
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
        return (localDevices + airplayDevices + sonosDevices).filter { selected.contains($0.id) }
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
            if device.category == .airplay || device.category == .sonos,
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
        if sonosCasts[source]?[device.id] != nil {
            scheduleSonosVolume(deviceID: device.id, source: source)
        }
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
        for (source, casts) in sonosCasts {
            for deviceID in casts.keys { scheduleSonosVolume(deviceID: deviceID, source: source) }
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
                for deviceID in Array(sonosCasts[source]?.keys ?? [:].keys) {
                    stopSonos(deviceID: deviceID, source: source)
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
        for deviceID in Array(sonosCasts[source]?.keys ?? [:].keys) {
            stopSonos(deviceID: deviceID, source: source)
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
        syncSonos(for: source, selected: selected)
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

    // MARK: - Sonos S1

    private func syncSonos(for source: CastSource, selected: Set<String>) {
        let wanted = Set(selected.filter { $0.hasPrefix("sonos:") })
        let current = Set(sonosCasts[source]?.keys ?? [:].keys)
        for deviceID in current.subtracting(wanted) {
            stopSonos(deviceID: deviceID, source: source)
        }
        for deviceID in wanted.subtracting(current) {
            startSonos(deviceID: deviceID, source: source)
        }
    }

    private func startSonos(deviceID: String, source: CastSource) {
        guard let session = runningSessions[source] else { return }
        guard let receiver = sonosReceiversByDeviceID[deviceID] else {
            sonosStatus[deviceID] = "Not found on the network"
            return
        }
        let streamer = SonosAudioStreamer(
            receiver: receiver,
            source: session.ringBuffer,
            sampleRate: session.capture.sampleRate
        )
        let cast = SonosCast(streamer: streamer)
        sonosCasts[source, default: [:]][deviceID] = cast
        sonosStatus[deviceID] = "Connecting…"
        let previousStop = sonosStopTasks[deviceID]

        cast.startTask = Task { [weak self] in
            guard let self else { return }
            await previousStop?.value
            guard !Task.isCancelled, self.sonosCasts[source]?[deviceID] === cast else { return }
            do {
                if let gain = self.perDeviceGainBySource[source]?[deviceID] {
                    try await SonosUPnPClient.setVolume(
                        self.volume(gain: gain * self.masterVolume), for: receiver
                    )
                }
                try await streamer.start()
                guard !Task.isCancelled, self.sonosCasts[source]?[deviceID] === cast else {
                    await streamer.stop()
                    return
                }
                self.sonosStatus[deviceID] = "Playing"
                self.lastErrorBySource[source] = nil
            } catch {
                await streamer.stop()
                guard self.sonosCasts[source]?[deviceID] === cast else { return }
                self.sonosStatus[deviceID] = "Failed"
                self.lastErrorBySource[source] = "Sonos \(receiver.name) failed: \(error)"
                NSLog("[SoundCast][AppState] Sonos \(deviceID) failed: \(error)")
            }
        }
    }

    func retrySonos(deviceID: String, source: CastSource) {
        guard selectedDeviceIDsBySource[source]?.contains(deviceID) == true,
              (sonosStatus[deviceID] == "Failed" || sonosStatus[deviceID] == "Not found on the network") else { return }
        lastErrorBySource[source] = nil
        stopSonos(deviceID: deviceID, source: source)
        startSonos(deviceID: deviceID, source: source)
    }

    private func stopSonos(deviceID: String, source: CastSource) {
        guard let cast = sonosCasts[source]?.removeValue(forKey: deviceID) else { return }
        if sonosCasts[source]?.isEmpty == true { sonosCasts[source] = nil }
        sonosVolumeTasks.removeValue(forKey: deviceID)?.cancel()
        sonosVolumeGeneration[deviceID, default: 0] += 1
        sonosStatus[deviceID] = nil
        cast.startTask?.cancel()
        let previousStop = sonosStopTasks[deviceID]
        let stopID = UUID()
        sonosStopGeneration[deviceID] = stopID
        let startTask = cast.startTask
        let stopTask = Task { [weak self] in
            await previousStop?.value
            await startTask?.value
            await cast.streamer.stop()
            guard let self, self.sonosStopGeneration[deviceID] == stopID else { return }
            self.sonosStopTasks[deviceID] = nil
            self.sonosStopGeneration[deviceID] = nil
        }
        sonosStopTasks[deviceID] = stopTask
    }

    private func scheduleSonosVolume(deviceID: String, source: CastSource) {
        guard let receiver = sonosReceiversByDeviceID[deviceID],
              let gain = perDeviceGainBySource[source]?[deviceID] else { return }
        sonosVolumeTasks.removeValue(forKey: deviceID)?.cancel()
        let generation = sonosVolumeGeneration[deviceID, default: 0] + 1
        sonosVolumeGeneration[deviceID] = generation
        let desiredVolume = volume(gain: gain * masterVolume)
        sonosVolumeTasks[deviceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled,
                  self.sonosVolumeGeneration[deviceID] == generation else { return }
            do {
                try await SonosUPnPClient.setVolume(desiredVolume, for: receiver)
                if self.sonosVolumeGeneration[deviceID] == generation {
                    self.sonosVolumeTasks[deviceID] = nil
                }
            } catch {
                if self.sonosVolumeGeneration[deviceID] == generation {
                    self.sonosStatus[deviceID] = "Volume update failed"
                    NSLog("[SoundCast][AppState] Sonos volume update for \(deviceID) failed: \(error)")
                    self.sonosVolumeTasks[deviceID] = nil
                }
            }
        }
    }

    private func volume(gain: Float) -> Int {
        Int((max(0, min(1, gain)) * 100).rounded())
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
                self.reconnectAttempts[deviceID] = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.airPlayFailed(deviceID: deviceID, source: source, error: error)
            }
        }
    }

    private func stopAirPlay(deviceID: String, source: CastSource) {
        reconnectTasks.removeValue(forKey: deviceID)?.cancel()
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
        stopAirPlay(deviceID: deviceID, source: source)
        if case AirPlayRealtimeSender.SenderError.notPaired = error {
            airplayStatus[deviceID] = "Not paired with SoundCast yet"
            unpairedAirPlayDevices.insert(deviceID)
            return
        }
        // Anything else (receiver restarted, slept, ended the session,
        // network blip, not found yet): keep retrying while the room is
        // still ticked under a running source, backing off 2 → 30 s.
        let attempt = (reconnectAttempts[deviceID] ?? 0) + 1
        reconnectAttempts[deviceID] = attempt
        let delay = min(30.0, pow(2.0, Double(attempt)))
        airplayStatus[deviceID] = "Reconnecting…"
        NSLog("[SoundCast][AppState] AirPlay \(deviceID): reconnect attempt \(attempt) in \(Int(delay)) s")
        reconnectTasks[deviceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTasks[deviceID] = nil
            guard self.runningSessions[source] != nil,
                  self.selectedDeviceIDsBySource[source]?.contains(deviceID) == true,
                  self.airplayCasts[source]?[deviceID] == nil else { return }
            self.startAirPlay(deviceID: deviceID, source: source)
        }
    }

    // MARK: - AirPlay pairing

    /// Step 1: ask the receiver to show a PIN. The connection must stay
    /// open until `submitPairingPIN` (closing it suppresses the PIN —
    /// design doc §12.5).
    func beginPairing(_ device: SoundDevice) {
        guard pairing == nil, let serviceName = airplayServiceNames[device.id] else { return }
        pairing = (device.id, .requestingPIN)
        Task {
            do {
                let receiver = try await AirPlayReceiverResolver.resolve(serviceName: serviceName)
                let connection = AirPlayRTSPConnection(
                    host: NWEndpoint.Host(receiver.scopedIPv6),
                    port: NWEndpoint.Port(rawValue: receiver.port)!
                )
                try await connection.connect()
                try await AirPlayPairSetup.startPinFlow(connection: connection)
                guard pairing?.deviceID == device.id else {
                    connection.close()
                    return
                }
                pairingConnection = connection
                pairing = (device.id, .waitingForPIN)
            } catch {
                pairing = (device.id, .failed("Couldn't reach \(device.name): \(error)"))
            }
        }
    }

    /// Step 2: complete pair-setup with the PIN shown on the receiver.
    func submitPairingPIN(_ pin: String) {
        guard let current = pairing, current.step == .waitingForPIN, let connection = pairingConnection else { return }
        let deviceID = current.deviceID
        pairing = (deviceID, .verifying)
        Task {
            do {
                try await AirPlayPairSetup.completeSetup(
                    connection: connection, identity: airplayIdentity,
                    setupCode: pin.trimmingCharacters(in: .whitespaces), transient: false
                )
                connection.close()
                pairingConnection = nil
                pairing = nil
                unpairedAirPlayDevices.remove(deviceID)
                airplayStatus[deviceID] = "Paired"
                // Start right away if this room is ticked under a running source.
                for source in Self.allSources where runningSessions[source] != nil
                    && selectedDeviceIDsBySource[source]?.contains(deviceID) == true {
                    startAirPlay(deviceID: deviceID, source: source)
                }
            } catch {
                connection.close()
                pairingConnection = nil
                pairing = (deviceID, .failed("Pairing failed — check the PIN and try again."))
                NSLog("[SoundCast][AppState] pair-setup failed: \(error)")
            }
        }
    }

    func cancelPairing() {
        pairingConnection?.close()
        pairingConnection = nil
        pairing = nil
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
