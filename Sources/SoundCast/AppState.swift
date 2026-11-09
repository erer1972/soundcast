import Combine
import CoreAudio
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
    /// 0 = solid, 1 = most see-through; for the widget and menu backgrounds.
    @Published var transparency: Double =
        (UserDefaults.standard.object(forKey: "Transparency") as? Double) ?? 0.5 {
        didSet { UserDefaults.standard.set(transparency, forKey: "Transparency") }
    }
    /// Recent audio level (0...1) per running source, for the meters.
    @Published private(set) var sourceLevels: [CastSource: Float] = [:]
    private var levelTask: Task<Void, Never>?
    /// Extra delay (ms, may be negative) for this Mac's outputs on top of
    /// the AirPlay alignment, to absorb e.g. a TV's own audio delay.
    @Published private(set) var syncOffsetMilliseconds: Double =
        UserDefaults.standard.double(forKey: AppState.syncOffsetKey)
    private static let syncOffsetKey = "SyncOffsetMilliseconds"
    private var syncOffsetTask: Task<Void, Never>?
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
    private var discoveredAirPlayReceivers: [AirPlayReceiver] = []
    /// One PTP grandmaster for every AirPlay session (UDP 319/320 can
    /// only be bound once). Created on first use, stopped when idle.
    private var ptpClock: AirPlayPTPClock?
    private let airplayIdentity = AirPlayIdentity.loadOrCreate()

    // Bonjour discovery feeds the grouped network-device lists.
    private let airPlayDiscovery = AirPlayDiscovery()
    private let sonosDiscovery = SonosDiscovery()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // A previous run that switched the output and then crashed.
        restoreSystemOutput()
        watchLocalDevices()
        airPlayDiscovery.$receivers
            .sink { [weak self] receivers in
                guard let self else { return }
                for receiver in receivers {
                    self.airplayServiceNames["airplay:\(receiver.id)"] = receiver.name
                }
                self.discoveredAirPlayReceivers = receivers
                self.updateAirPlayDevices()
            }
            .store(in: &cancellables)
        sonosDiscovery.$receivers
            .sink { [weak self] receivers in
                guard let self else { return }
                self.sonosReceiversByDeviceID = Dictionary(uniqueKeysWithValues: receivers.map { ("sonos:\($0.id)", $0) })
                defer { self.updateAirPlayDevices() }
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
    private var resumeSources: Set<CastSource> = [.virtualDevice(.main)]

    /// The panel's single master switch: off stops every source (remembering
    /// which was on); on restores it, or "SoundCast" the first time.
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
    /// Meter level for a device: the loudest running source it plays.
    func level(for device: SoundDevice) -> Float {
        Self.allSources
            .filter { selectedDeviceIDsBySource[$0]?.contains(device.id) == true }
            .compactMap { sourceLevels[$0] }
            .max() ?? 0
    }

    /// Samples each session's peak ~12 times a second while any source runs.
    private func updateLevelMetering() {
        guard !runningSessions.isEmpty else {
            levelTask?.cancel()
            levelTask = nil
            if !sourceLevels.isEmpty { sourceLevels = [:] }
            return
        }
        guard levelTask == nil else { return }
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard let self else { return }
                var levels: [CastSource: Float] = [:]
                for (source, session) in self.runningSessions {
                    let peak = min(1, session.ringBuffer.takePeak())
                    // Fast attack, slower release, so the bars don't flicker.
                    levels[source] = max(peak, (self.sourceLevels[source] ?? 0) * 0.7)
                }
                if levels != self.sourceLevels { self.sourceLevels = levels }
            }
        }
    }

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

    /// Keeps the local device list current as speakers connect and
    /// disconnect (e.g. a Bluetooth speaker moving to another Mac). Ticks
    /// are kept: a missing device is skipped and returns when it does.
    private func watchLocalDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = Set(self.localDevices.map(\.id))
                self.refreshDeviceList()
                guard Set(self.localDevices.map(\.id)) != before else { return }
                NSLog("[SoundCast][AppState] output devices changed: \(self.localDevices.map(\.name))")
                for source in Self.allSources where self.isActive(source) {
                    self.applySelectionToRunningOutput(for: source)
                }
            }
        }
    }

    /// "Couldn't start BP10 (macOS error 'nope')" instead of a raw OSStatus.
    private func describe(_ error: Error, devices: [SoundDevice]) -> String {
        let names = devices.map(\.name).joined(separator: ", ")
        switch error {
        case LocalOutputEngine.OutputError.failedToStartIO(let status),
             LocalOutputEngine.OutputError.failedToCreateAggregateDevice(let status):
            let code = UInt32(bitPattern: status)
            let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
            let fourCC = bytes.allSatisfy { (0x20...0x7E).contains($0) }
                ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(status)"
            return "Couldn't play to \(names.isEmpty ? "the selected outputs" : names) (macOS error \(fourCC)). Is it connected to this Mac?"
        default:
            return "\(error)"
        }
    }

    func refreshDeviceList() {
        localDevices = LocalDeviceEnumerator.listOutputDevices()
        for source in Self.allSources {
            for device in localDevices where perDeviceGainBySource[source]?[device.id] == nil {
                perDeviceGainBySource[source, default: [:]][device.id] = 1.0
            }
        }
    }

    /// Publishes AirPlay receivers, leaving out Sonos speakers (by their
    /// AirPlay "manufacturer" field, or matched against Sonos discovery):
    /// those play through the Sonos (UPnP) path, which needs no pairing,
    /// while their AirPlay side would ask for a PIN they can't display.
    /// A hidden entry that was ticked is unticked.
    private func updateAirPlayDevices() {
        let sonosMACs = Set(sonosReceiversByDeviceID.values.compactMap { Self.sonosMAC(fromID: $0.id) })
        let sonosNames = Set(sonosReceiversByDeviceID.values.map(\.name))
        let visible = discoveredAirPlayReceivers.filter { receiver in
            receiver.manufacturer?.caseInsensitiveCompare("Sonos") != .orderedSame
                && !sonosMACs.contains(Self.normalizedMAC(receiver.id)) && !sonosNames.contains(receiver.name)
        }
        airplayDevices = visible.map { receiver in
            SoundDevice(id: "airplay:\(receiver.id)", name: receiver.name, category: .airplay, audioObjectID: nil)
        }
        let visibleIDs = Set(airplayDevices.map(\.id))
        for source in Self.allSources {
            let hidden = (selectedDeviceIDsBySource[source] ?? []).filter { $0.hasPrefix("airplay:") && !visibleIDs.contains($0) }
            guard !hidden.isEmpty else { continue }
            selectedDeviceIDsBySource[source]?.subtract(hidden)
            if isActive(source) { applySelectionToRunningOutput(for: source) }
        }
    }

    /// "RINCON_804AF2D0F61A01400" -> "804AF2D0F61A".
    private static func sonosMAC(fromID id: String) -> String? {
        guard id.hasPrefix("RINCON_") else { return nil }
        let hex = id.dropFirst(7).prefix(12)
        return hex.count == 12 ? hex.uppercased() : nil
    }

    /// "80:4A:F2:D0:F6:1A" -> "804AF2D0F61A".
    private static func normalizedMAC(_ value: String) -> String {
        value.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
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

    /// Extra delay (ms, may be negative) added to the latency reported to
    /// video players only, to fine-tune lip sync by eye.
    @Published private(set) var videoSyncMilliseconds: Double =
        UserDefaults.standard.double(forKey: "VideoSyncMilliseconds")

    func setVideoSync(milliseconds: Double) {
        let value = max(-500, min(500, milliseconds.rounded()))
        guard value != videoSyncMilliseconds else { return }
        videoSyncMilliseconds = value
        UserDefaults.standard.set(value, forKey: "VideoSyncMilliseconds")
        for source in Self.allSources where isActive(source) {
            guard let session = runningSessions[source] else { continue }
            publishLatency(for: source, outputEngine: session.output, selected: selectedDeviceIDsBySource[source] ?? [])
        }
    }

    /// Web control page (see WebControl.swift); address shown in the menu.
    var webControl: WebControlServer?
    @Published var webControlAddress: String?

    @Published private(set) var calibrationStatus: String?
    @Published private(set) var isCalibrating = false

    /// Measures how much later the AirPlay rooms are heard than this Mac's
    /// speakers (clicks + microphone, see SyncCalibrator) and sets the
    /// AirPlay Sync offset to match. Other rooms are muted per round and
    /// every volume is restored afterwards.
    func calibrateSync() {
        guard !isCalibrating else { return }
        guard let source = Self.allSources.first(where: { isActive($0) && runningSessions[$0] != nil }),
              let session = runningSessions[source] else {
            calibrationStatus = "Turn on a source first."
            return
        }
        let selected = selectedDeviceIDsBySource[source] ?? []
        let localIDs = localDevices.filter { selected.contains($0.id) }.map(\.id)
        let airplayIDs = selected.filter { $0.hasPrefix("airplay:") && airplayCasts[source]?[$0]?.sender != nil }
        guard !localIDs.isEmpty, !airplayIDs.isEmpty else {
            calibrationStatus = "Tick at least one speaker on this Mac and one playing Apple TV."
            return
        }
        let sonosReceivers = (sonosCasts[source]?.keys).map { Array($0) }?.compactMap { sonosReceiversByDeviceID[$0] } ?? []
        isCalibrating = true
        calibrationStatus = "Calibrating — pause other audio and stay quiet (about 25 s)…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func setLocal(muted: Bool) {
                for id in localIDs {
                    session.output.setGain(deviceID: id, gain: muted ? 0 : (self.perDeviceGainBySource[source]?[id] ?? 1))
                }
            }
            @MainActor func setAirPlay(muted: Bool) {
                for id in airplayIDs {
                    let gain = (self.perDeviceGainBySource[source]?[id] ?? 1) * self.masterVolume
                    self.airplayCasts[source]?[id]?.sender?.setVolume(muted ? 0 : gain)
                }
            }
            @MainActor func setSonos(muted: Bool) async {
                for receiver in sonosReceivers {
                    let id = "sonos:\(receiver.id)"
                    let gain = (self.perDeviceGainBySource[source]?[id] ?? 1) * self.masterVolume
                    try? await SonosUPnPClient.setVolume(muted ? 0 : self.volume(gain: gain), for: receiver)
                }
            }
            defer {
                setLocal(muted: false)
                setAirPlay(muted: false)
                Task { await setSonos(muted: false) }
                self.isCalibrating = false
            }
            do {
                guard await SyncCalibrator.requestMicrophoneAccess() else { throw SyncCalibrator.CalibrationError.microphoneDenied }
                let calibrator = SyncCalibrator(ring: session.ringBuffer)
                await setSonos(muted: true)

                setAirPlay(muted: true)
                try await Task.sleep(nanoseconds: 2_500_000_000)  // let the mute reach the Apple TVs
                let local = try await calibrator.measure()

                setLocal(muted: true)
                setAirPlay(muted: false)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let airplay = try await calibrator.measure()

                let difference = (airplay - local) * 1000
                // Local outputs are already aligned to AirPlay's nominal 2 s,
                // so a real difference is a TV/receiver delay of a few
                // hundred ms at most; anything bigger is a bad measurement.
                guard abs(difference) < 1000, airplay > 1 else {
                    throw SyncCalibrator.CalibrationError.implausible(differenceMilliseconds: Int(difference))
                }
                let wanted = self.syncOffsetMilliseconds + difference
                NSLog("[SoundCast][Calibrate] local \(String(format: "%.3f", local)) s, AirPlay \(String(format: "%.3f", airplay)) s, offset \(self.syncOffsetMilliseconds) -> \(wanted) ms")
                self.setSyncOffset(milliseconds: wanted)
                if abs(wanted) > 500 {
                    self.calibrationStatus = String(format: "Needed %+.0f ms, beyond the ±500 ms range; set to the limit.", wanted)
                } else {
                    self.calibrationStatus = String(format: "Calibrated: %+.0f ms (Apple TV was %+.0f ms vs. this Mac).", wanted, difference)
                }
            } catch {
                self.calibrationStatus = "Calibration failed: \(error)"
                NSLog("[SoundCast][Calibrate] failed: \(error)")
            }
        }
    }

    /// Saves the offset at once; rebuilds affected local outputs once the
    /// slider has been still for a moment (each rebuild re-buffers).
    func setSyncOffset(milliseconds: Double) {
        let value = max(-500, min(500, milliseconds.rounded()))
        guard value != syncOffsetMilliseconds else { return }
        syncOffsetMilliseconds = value
        UserDefaults.standard.set(value, forKey: Self.syncOffsetKey)
        syncOffsetTask?.cancel()
        syncOffsetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            for source in Self.allSources where self.isActive(source)
                && self.selectedDeviceIDsBySource[source]?.contains(where: { $0.hasPrefix("airplay:") }) == true {
                self.applySelectionToRunningOutput(for: source)
            }
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
            // "Cast Everything" mutes every app at the source while it taps
            // them, which silences what apps send to the SoundCast device
            // too, so the two sources can't usefully run together.
            for other in Self.allSources where other != source && isActive(other) {
                NSLog("[SoundCast][AppState] turning off \(other.displayName) (only one source at a time)")
                setActive(other, on: false)
            }
            // Route the Mac's sound into the virtual device first: playing
            // to it is also what makes the driver create its shared buffer.
            if case .virtualDevice(let preset) = source { switchSystemOutput(to: preset) }
            startSession(source)
            if !isActive(source) { restoreSystemOutput() }
        } else {
            stopSession(source)
            if case .virtualDevice = source { restoreSystemOutput() }
        }
    }

    // MARK: - System output switching

    /// UID of the output that was selected before SoundCast took over.
    /// Kept in UserDefaults so a crash can be undone on the next launch.
    private static let savedSystemOutputKey = "SavedSystemOutputUID"

    private func switchSystemOutput(to preset: VirtualDevicePreset) {
        guard let current = SystemOutputDevice.currentUID(), current != preset.deviceUID else { return }
        if !current.hasPrefix("com.soundcast.device") {
            UserDefaults.standard.set(current, forKey: Self.savedSystemOutputKey)
        }
        if SystemOutputDevice.select(uid: preset.deviceUID) {
            NSLog("[SoundCast][AppState] system output switched to \(preset.displayName) (was \(current))")
        } else {
            NSLog("[SoundCast][AppState] could not switch system output to \(preset.displayName)")
        }
    }

    /// Puts back the output saved by `switchSystemOutput`, unless the user
    /// has picked a different output themselves in the meantime.
    func restoreSystemOutput() {
        guard let saved = UserDefaults.standard.string(forKey: Self.savedSystemOutputKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.savedSystemOutputKey)
        guard SystemOutputDevice.currentUID()?.hasPrefix("com.soundcast.device") == true else { return }
        if SystemOutputDevice.select(uid: saved) {
            NSLog("[SoundCast][AppState] system output restored to \(saved)")
        } else {
            NSLog("[SoundCast][AppState] could not restore system output \(saved) (no longer available?)")
        }
    }

    private enum StartOutcome { case started, waitingForDriver, failed }

    /// Virtual-device sources whose shared buffer doesn't exist yet (the
    /// driver creates it on first use) are retried once a second until it
    /// appears, the user switches the source off, or a different error hits.
    private var retryTasks: [CastSource: Task<Void, Never>] = [:]
    private var outdatedDriverSources: Set<CastSource> = []

    private func startSession(_ source: CastSource) {
        switch attemptStart(source) {
        case .started, .failed:
            break
        case .waitingForDriver:
            // Show it as on ("armed") so the toggle reflects the user's intent.
            activeSources.insert(source)
            lastErrorBySource[source] = outdatedDriverSources.contains(source)
                ? "Waiting for the updated SoundCast driver — play something to \"\(source.displayName)\". If this stays, reinstall the driver."
                : "Waiting for audio to be played to \"\(source.displayName)\"…"
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
        // ~5s of 48kHz stereo float32 — headroom for the
        // capture-to-render handoff; Phase 2/3 consumers (AirPlay
        // senders, Sonos stream) get their own, separately-sized ring
        // buffers fed from the same capture callback, per design doc §6.
        // Holds the AirPlay alignment delay (2 s) for local outputs plus headroom.
        let buffer = RingBuffer(capacitySamples: 48_000 * 2 * 5)

        let captureEngine: AudioCaptureSource = switch source {
        case .globalTap: ProcessTapCapture(ringBuffer: buffer)
        case .virtualDevice(let preset): VirtualDeviceCapture(ringBuffer: buffer, preset: preset)
        }
        let outputEngine = LocalOutputEngine(sourceRingBuffer: buffer)
        outputEngine.masterGain = masterVolume

        do {
            try captureEngine.start()
            outputEngine.sourceSampleRate = captureEngine.sampleRate
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
            outdatedDriverSources.remove(source)
            updateLevelMetering()
            return .started
        } catch {
            captureEngine.stop()
            outputEngine.stop()
            if case .virtualDevice = source,
               case VirtualDeviceCapture.CaptureError.shmOpenFailed(let code) = error,
               code == ENOENT {
                return .waitingForDriver
            }
            if case .virtualDevice = source,
               case VirtualDeviceCapture.CaptureError.outdatedLayout = error {
                outdatedDriverSources.insert(source)
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
        updateLevelMetering()
    }

    private func applySelectionToRunningOutput(for source: CastSource) {
        guard let session = runningSessions[source] else { return }
        do {
            try applySelection(on: session.output, for: source)
            if lastErrorBySource[source]?.hasPrefix("Couldn't play to") == true { lastErrorBySource[source] = nil }
        } catch {
            let selected = selectedDeviceIDsBySource[source] ?? []
            lastErrorBySource[source] = describe(error, devices: localDevices.filter { selected.contains($0.id) })
            NSLog("[SoundCast][AppState] applySelectionToRunningOutput(\(source.displayName)) failed: \(error)")
        }
    }

    /// Tells the SoundCast device how late its audio is heard, so video
    /// players (Safari, Chrome, QuickTime) delay the picture to match:
    /// the later of the local outputs and the AirPlay rooms. Sonos is not
    /// counted yet (its buffering hasn't been measured).
    private func publishLatency(for source: CastSource, outputEngine: LocalOutputEngine, selected: Set<String>) {
        guard let capture = runningSessions[source]?.capture as? VirtualDeviceCapture else { return }
        var latency = outputEngine.heardLatencySeconds
        if selected.contains(where: { $0.hasPrefix("airplay:") }) {
            latency = max(latency, AirPlayRealtimeSender.playbackLatencySeconds + max(0, syncOffsetMilliseconds / 1000))
        }
        latency = max(0, latency + videoSyncMilliseconds / 1000)
        capture.setReportedLatency(seconds: latency)
        NSLog("[SoundCast][AppState] reporting \(String(format: "%.3f", latency)) s latency on \(source.displayName)")
    }

    private func applySelection(on outputEngine: LocalOutputEngine, for source: CastSource) throws {
        let selected = selectedDeviceIDsBySource[source] ?? []
        syncAirPlay(for: source, selected: selected)
        syncSonos(for: source, selected: selected)
        let gains = perDeviceGainBySource[source] ?? [:]
        let targets = localDevices
            .filter { selected.contains($0.id) }
            .map { LocalOutputEngine.Target(device: $0, gain: gains[$0.id] ?? 1.0) }
        defer { publishLatency(for: source, outputEngine: outputEngine, selected: selected) }
        guard !targets.isEmpty else {
            outputEngine.stop()
            return
        }
        // AirPlay rooms play a fixed time after capture; hold local
        // outputs back by the same amount so every room is in step.
        outputEngine.alignmentDelaySeconds = selected.contains { $0.hasPrefix("airplay:") }
            ? max(0, AirPlayRealtimeSender.playbackLatencySeconds + syncOffsetMilliseconds / 1000) : 0
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
