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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                state.toggleDevice(device, for: source)
            } label: {
                HStack {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    Text(device.name)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isSelected {
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
