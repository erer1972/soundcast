import AppKit
import SwiftUI

/// Borderless panel that can take clicks (sliders, switches) without
/// activating SoundCast or stealing focus from the app being used.
private final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the always-on-top desktop panel: show/hide, size (compact or
/// expanded), position, and remembering all three between launches.
/// It is a plain window, so it needs no app extension, App Group or
/// Apple developer signing (unlike a real WidgetKit widget).
@MainActor
final class FloatingPanelController: ObservableObject {
    static let compactSize = NSSize(width: 364, height: 176)
    static let expandedSize = NSSize(width: 364, height: 430)

    @Published private(set) var isVisible: Bool
    @Published private(set) var isExpanded: Bool

    private let state: AppState
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    private enum Key {
        static let visible = "floatingPanel.visible"
        static let expanded = "floatingPanel.expanded"
        static let originX = "floatingPanel.originX"
        static let topY = "floatingPanel.topY"
    }

    init(state: AppState) {
        self.state = state
        let defaults = UserDefaults.standard
        self.isVisible = defaults.bool(forKey: Key.visible)
        self.isExpanded = defaults.bool(forKey: Key.expanded)
        if isVisible {
            // Wait until the app has finished launching before creating a window.
            DispatchQueue.main.async { [weak self] in self?.show() }
        }
    }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    func show() {
        state.refreshDeviceList()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        isVisible = true
        UserDefaults.standard.set(true, forKey: Key.visible)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        UserDefaults.standard.set(false, forKey: Key.visible)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        UserDefaults.standard.set(expanded, forKey: Key.expanded)
        guard let panel else { return }
        // Keep the top-left corner fixed; grow/shrink downward like a widget.
        let size = expanded ? Self.expandedSize : Self.compactSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: true)
        saveOrigin()
    }

    // MARK: - Window construction

    private func makePanel() -> NSPanel {
        let size = isExpanded ? Self.expandedSize : Self.compactSize
        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: WidgetPanelView(state: state, controller: self))
        panel.contentView = host
        panel.setFrameOrigin(initialOrigin(for: size))

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveOrigin() }
        }
        return panel
    }

    /// Saved position if there is one (and it is still on a screen),
    /// otherwise the top-right corner of the main screen.
    private func initialOrigin(for size: NSSize) -> NSPoint {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Key.originX) != nil {
            let x = defaults.double(forKey: Key.originX)
            let top = defaults.double(forKey: Key.topY)
            let origin = NSPoint(x: x, y: top - size.height)
            let probe = NSRect(origin: origin, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(probe) }) {
                return origin
            }
        }
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.maxX - size.width - 20, y: area.maxY - size.height - 20)
    }

    /// Stored as left edge + top edge, so expanding/collapsing keeps the same anchor.
    private func saveOrigin() {
        guard let frame = panel?.frame else { return }
        let defaults = UserDefaults.standard
        defaults.set(frame.minX, forKey: Key.originX)
        defaults.set(frame.maxY, forKey: Key.topY)
    }
}
