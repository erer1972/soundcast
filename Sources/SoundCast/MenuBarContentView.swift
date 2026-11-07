import SwiftUI
import SoundCastCore

struct MenuBarContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var panel: FloatingPanelController

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

            Divider()

            Text("Each source below is independent — turn on several at once to route different apps/presets to different rooms simultaneously.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AppState.allSources, id: \.self) { source in
                        SourceSection(source: source, state: state)
                    }
                }
            }
            .frame(maxHeight: 360)

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
        .onAppear {
            state.refreshDeviceList()
        }
    }
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
    // Sonos entries are discovered but not yet wired to any output —
    // show them, but don't let the user tick a box that would silently
    // do nothing. AirPlay rooms stream via AirPlayRealtimeSender.
    var isInteractive: Bool { device.category != .sonos }
    var airplayStatus: String? { device.category == .airplay ? state.airplayStatus[device.id] : nil }

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
                        if let airplayStatus {
                            Text(airplayStatus)
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
