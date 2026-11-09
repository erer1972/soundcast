import SwiftUI
import SoundCastCore

struct MenuBarContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var panel: FloatingPanelController
    @State private var sourceListHeight: CGFloat = 0

    /// The menu grows with expanded sources; it only scrolls once it would
    /// no longer fit on the screen (leaving room for the other controls).
    private var maxSourceListHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screenHeight - 260)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Master Volume")
                Slider(
                    value: Binding(
                        get: { Double(state.masterVolume) },
                        set: { state.setMasterVolume(Float($0)) }
                    ),
                    in: 0...1
                )
            }

            HStack {
                Text("AirPlay Sync")
                Slider(
                    value: Binding(
                        get: { state.syncOffsetMilliseconds },
                        set: { state.setSyncOffset(milliseconds: $0) }
                    ),
                    in: -500...500,
                    step: 10
                )
                Text(String(format: "%+.0f ms", state.syncOffsetMilliseconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 58, alignment: .trailing)
                Button {
                    state.setSyncOffset(milliseconds: 0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .help("Reset to 0 ms")
            }
            .help("Delays this Mac's speakers (including Bluetooth) relative to AirPlay rooms. Increase if they play ahead of the Apple TVs, decrease if behind.")

            Divider()

            Text("One source at a time: \"Cast Everything\" sends all Mac audio; \"SoundCast\" sends what plays to the SoundCast output (turning it on selects that output for you).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // A menu-bar window sizes to its content's minimum, which for a
            // bare ScrollView is zero height, so size it to the measured
            // content, capped at what fits on screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AppState.allSources, id: \.self) { source in
                        SourceSection(source: source, state: state)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SourceListHeightKey.self, value: proxy.size.height)
                })
            }
            .frame(height: min(max(sourceListHeight, 1), maxSourceListHeight))
            .onPreferenceChange(SourceListHeightKey.self) { sourceListHeight = $0 }

            HStack {
                Text("Transparency")
                Slider(value: $state.transparency, in: 0...1)
            }

            Divider()

            Toggle("Show Floating Panel", isOn: Binding(
                get: { panel.isVisible },
                set: { panel.setVisible($0) }
            ))

            Toggle("Launch at Login", isOn: Binding(
                get: { state.launchAtLoginEnabled },
                set: { state.setLaunchAtLogin($0) }
            ))

            Button("Refresh Devices") {
                state.refreshDeviceList()
            }

            Divider()

            Button("Quit SoundCast") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 300)
        .background {
            // Our own blur (same as the widget) replaces the system one,
            // which MenuWindowTransparency neutralises.
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(1 - state.transparency * 0.75)
                .ignoresSafeArea()
        }
        .background(MenuWindowTransparency())
        .onAppear {
            state.refreshDeviceList()
        }
    }
}

private struct SourceListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One source (global tap, or one virtual-device preset): its own
/// on/off toggle plus, while expanded, its own device checklist —
/// entirely independent of every other source's state.
private struct SourceSection: View {
    let source: AppState.CastSource
    @ObservedObject var state: AppState
    @State private var isExpanded = false

    var isActive: Bool { state.isActive(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(source.displayName, isOn: Binding(
                    get: { isActive },
                    set: { state.setActive(source, on: $0) }
                ))
                .toggleStyle(.switch)

                Spacer()

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
            }

            if let error = state.lastErrorBySource[source] {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if case .virtualDevice = source, isExpanded || isActive {
                Text("Point one app's output at \"\(source.displayName)\" (its own output picker, or System Settings → Sound) to route just that app here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.groupedDevices, id: \.0) { category, devices in
                        if !devices.isEmpty {
                            Text(category.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            ForEach(devices) { device in
                                DeviceRow(device: device, source: source, state: state)
                            }
                        }
                    }
                    if state.groupedDevices.allSatisfy({ $0.1.isEmpty }) {
                        Text("No devices found yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 12)
            }

            Divider()
        }
    }
}

private struct DeviceRow: View {
    let device: SoundDevice
    let source: AppState.CastSource
    @ObservedObject var state: AppState

    var isSelected: Bool { state.selectedDeviceIDsBySource[source]?.contains(device.id) ?? false }
    var isInteractive: Bool { true }
    var deviceStatus: String? { state.airplayStatus[device.id] ?? state.sonosStatus[device.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isInteractive {
                Button {
                    state.toggleDevice(device, for: source)
                } label: {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        Text(device.name)
                        Spacer()
                        if let deviceStatus {
                            Text(deviceStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Text(device.name)
                    Spacer()
                    Text("coming soon")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if device.category == .airplay {
                AirPlayPairingControls(device: device, state: state)
                    .padding(.leading, 22)
            }

            if isSelected && isInteractive {
                Slider(
                    value: Binding(
                        get: { Double(state.perDeviceGainBySource[source]?[device.id] ?? 1.0) },
                        set: { state.setGain(for: device, source: source, gain: Float($0)) }
                    ),
                    in: 0...1
                )
                .padding(.leading, 22)
            }

            if isSelected, device.category == .sonos,
                    (state.sonosStatus[device.id] == "Failed" || state.sonosStatus[device.id] == "Not found on the network") {
                HStack {
                    Spacer()
                    Button {
                        state.retrySonos(deviceID: device.id, source: source)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                }
                .padding(.leading, 22)
            }
        }
    }
}

/// "Pair…" for a room that rejected SoundCast's identity, then a PIN field
/// once the receiver is showing its code (design doc §12.5: the PIN only
/// appears while the triggering connection stays open).
private struct AirPlayPairingControls: View {
    let device: SoundDevice
    @ObservedObject var state: AppState
    @State private var pin = ""

    var body: some View {
        if let pairing = state.pairing, pairing.deviceID == device.id {
            switch pairing.step {
            case .requestingPIN:
                Text("Asking \(device.name) to show a PIN…").font(.caption2).foregroundStyle(.secondary)
            case .waitingForPIN:
                HStack(spacing: 6) {
                    TextField("PIN shown on \(device.name)", text: $pin)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit { submit() }
                    Button("Pair") { submit() }
                        .disabled(pin.trimmingCharacters(in: .whitespaces).count < 4)
                    Button("Cancel") { state.cancelPairing() }
                }
                .font(.caption)
            case .verifying:
                Text("Pairing…").font(.caption2).foregroundStyle(.secondary)
            case .failed(let message):
                HStack(spacing: 6) {
                    Text(message).font(.caption2).foregroundStyle(.red)
                    Button("Try again") {
                        state.cancelPairing()
                        state.beginPairing(device)
                    }
                    .font(.caption2)
                }
            }
        } else if state.unpairedAirPlayDevices.contains(device.id) {
            Button("Pair with SoundCast…") {
                pin = ""
                state.beginPairing(device)
            }
            .font(.caption2)
            .disabled(state.pairing != nil)
        }
    }

    private func submit() {
        guard pin.trimmingCharacters(in: .whitespaces).count >= 4 else { return }
        state.submitPairingPIN(pin)
    }
}

/// The menu-bar window draws its blur in a visual-effect view that wraps
/// the SwiftUI content, so fading it would fade the text too. Instead,
/// switch it to blend within the (clear) window, which makes it
/// effectively see-through; the content draws its own adjustable blur.
private struct MenuWindowTransparency: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            var changed = 0
            var view: NSView? = superview
            while let current = view {
                if let effect = current as? NSVisualEffectView {
                    effect.blendingMode = .withinWindow
                    effect.state = .active
                    changed += 1
                }
                view = current.superview
            }
            NSLog("[SoundCast][Menu] transparency: switched \(changed) enclosing background view(s)")
        }
    }
}
