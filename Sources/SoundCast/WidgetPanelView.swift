import SwiftUI
import SoundCastCore

/// The floating desktop panel's contents (design: "SoundCast Widget"
/// mockup). Compact shows casting state, master volume and active
/// devices; expanded adds per-source switches and per-device volume.
/// Choosing which devices are ticked stays in the menu bar window.
struct WidgetPanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var controller: FloatingPanelController

    private let accent = Color(red: 1.0, green: 0.48, blue: 0.35)
    private let live = Color(red: 0.43, green: 0.91, blue: 0.78)

    private var volumePercent: Int { Int((state.masterVolume * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if controller.isExpanded { expanded } else { compact }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // Lower opacity lets more of the desktop through the blur.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(1 - state.transparency * 0.75)
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .preferredColorScheme(.dark)
        .tint(accent)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isCasting ? live : .secondary)
                .frame(width: 8, height: 8)
            Text("SoundCast")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                controller.setExpanded(!controller.isExpanded)
            } label: {
                Image(systemName: controller.isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
            .help(controller.isExpanded ? "Collapse" : "Expand")
            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide panel (bring it back from the menu bar icon)")
            Toggle("Casting", isOn: Binding(get: { state.isCasting }, set: { state.setCasting($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .foregroundStyle(.primary)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.isCasting ? "Casting" : "Paused")
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        guard state.isCasting else { return "Switch on to resume" }
        let n = state.activeDevices.count
        if n == 0 { return "No devices ticked" }
        return n == 1 ? "1 device" : "\(n) devices"
    }

    private var masterSlider: some View {
        Slider(
            value: Binding(get: { Double(state.masterVolume) }, set: { state.setMasterVolume(Float($0)) }),
            in: 0...1
        )
        .accessibilityLabel("Master volume")
    }

    private var bigVolume: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(volumePercent)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("%")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Compact

    /// How many rooms fit in the compact list: 3 at the default height,
    /// one more for every ~30 pt the panel is dragged taller.
    private var compactRows: Int {
        let extra = controller.size.height - FloatingPanelController.compactSize.height
        return max(2, 3 + Int((extra / 30).rounded(.down)))
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading) {
                    statusBlock
                    Spacer(minLength: 0)
                    bigVolume
                }
                .frame(width: 118, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    if state.activeDevices.isEmpty {
                        Text(state.isCasting ? "Tick a device in the menu bar." : "—")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.activeDevices.prefix(compactRows)) { device in
                            DeviceLine(device: device, level: state.isCasting ? state.level(for: device) : 0)
                        }
                        if state.activeDevices.count > compactRows {
                            Text("+\(state.activeDevices.count - compactRows) more")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 8)
            masterSlider
        }
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                statusBlock
                Spacer()
                bigVolume
            }
            .padding(.top, 8)
            masterSlider.padding(.top, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = state.lastErrorBySource[state.castingSource] {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reason = state.fallbackReason {
                        Text("\(reason). Casting all Mac audio instead.")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(AppState.allSources.filter { state.isActive($0) }, id: \.self) { source in
                        let devices = state.selectedDevices(for: source)
                        if !devices.isEmpty {
                            SectionLabel("Rooms")
                            ForEach(devices) { device in
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack {
                                        Text(device.name).font(.system(size: 13, weight: .medium))
                                        Text(device.category.rawValue)
                                            .font(.system(size: 10.5))
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(.white.opacity(0.12), in: Capsule())
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        if let status = state.airplayStatus[device.id] ?? state.sonosStatus[device.id] {
                                            Text(status)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(status == "Failed" || status == "Volume update failed" ? .red : .secondary)
                                                .lineLimit(1)
                                        }
                                        if device.category == .sonos,
                                                         (state.sonosStatus[device.id] == "Failed" || state.sonosStatus[device.id] == "Not found on the network") {
                                            Button {
                                                state.retrySonos(deviceID: device.id, source: source)
                                            } label: {
                                                Image(systemName: "arrow.clockwise")
                                            }
                                            .buttonStyle(.plain)
                                            .help("Retry Sonos connection")
                                        }
                                    }
                                    Slider(
                                        value: Binding(
                                            get: { Double(state.perDeviceGainBySource[source]?[device.id] ?? 1.0) },
                                            set: { state.setGain(for: device, source: source, gain: Float($0)) }
                                        ),
                                        in: 0...1
                                    )
                                    .accessibilityLabel("\(device.name) volume")
                                }
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }
}

private struct DeviceLine: View {
    let device: SoundDevice
    let level: Float

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(device.category.rawValue).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            EqBars(level: level)
        }
    }
}

/// Five small level bars driven by the real audio level: they move with
/// the sound, and sit flat and grey when paused or silent (static height
/// per level when Reduce Motion is on).
private struct EqBars: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var playing: Bool { level > 0.01 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !playing || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Perceptual-ish scaling so quiet passages still move the bars.
            let loudness = Double(min(1, sqrt(level) * 1.2))
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = reduceMotion ? 0.8 : 0.55 + 0.45 * abs(sin(t * 5.3 + Double(i) * 1.7))
                    let height: Double = playing ? 0.15 + 0.85 * loudness * wobble : 0.15
                    RoundedRectangle(cornerRadius: 2)
                        .fill(playing ? Color(red: 0.43, green: 0.91, blue: 0.78) : Color.white.opacity(0.25))
                        .frame(width: 4, height: 22 * height)
                }
            }
            .frame(height: 22, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
