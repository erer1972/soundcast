import AppKit
import SwiftUI

/// Borderless panel that can take clicks (sliders, switches) without
/// activating SoundCast or stealing focus from the app being used.
private final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the desktop panel: show/hide, size (compact or
/// expanded), position, and remembering all three between launches.
/// It is a plain window, so it needs no app extension or shared container.
@MainActor
final class FloatingPanelController: ObservableObject {
    static let compactSize = NSSize(width: 364, height: 176)
    static let expandedSize = NSSize(width: 364, height: 430)
    /// Smallest sizes the edges can be dragged to (the layout stops fitting below these).
    static let compactMinSize = NSSize(width: 320, height: 150)
    static let expandedMinSize = NSSize(width: 320, height: 260)
    static let maxSize = NSSize(width: 900, height: 1200)

    @Published private(set) var isVisible: Bool
    @Published private(set) var isExpanded: Bool
    /// Current panel size, so the view can show more rows when it's bigger.
    @Published private(set) var size: NSSize = .zero

    private let state: AppState
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?

    private enum Key {
        static let visible = "floatingPanel.visible"
        static let expanded = "floatingPanel.expanded"
        static let originX = "floatingPanel.originX"
        static let topY = "floatingPanel.topY"
        static let compactSize = "floatingPanel.compactSize"
        static let expandedSize = "floatingPanel.expandedSize"
    }

    /// The size the user last dragged this mode to, or the default.
    private func savedSize(expanded: Bool) -> NSSize {
        let minSize = expanded ? Self.expandedMinSize : Self.compactMinSize
        guard let text = UserDefaults.standard.string(forKey: expanded ? Key.expandedSize : Key.compactSize) else {
            return expanded ? Self.expandedSize : Self.compactSize
        }
        let size = NSSizeFromString(text)
        return NSSize(width: min(max(size.width, minSize.width), Self.maxSize.width),
                      height: min(max(size.height, minSize.height), Self.maxSize.height))
    }

    private func applyMinSize(to panel: NSPanel) {
        panel.contentMinSize = isExpanded ? Self.expandedMinSize : Self.compactMinSize
        panel.contentMaxSize = Self.maxSize
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
        let size = savedSize(expanded: expanded)
        // Lower the minimum first so collapsing can shrink the window.
        panel.contentMinSize = Self.compactMinSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        self.size = size
        panel.setFrame(frame, display: true, animate: true)
        applyMinSize(to: panel)
        saveOrigin()
    }

    // MARK: - Window construction

    private func makePanel() -> NSPanel {
        let size = savedSize(expanded: isExpanded)
        self.size = size
        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: WidgetPanelView(state: state, controller: self))
        // The window decides the size (the user drags its edges); the
        // SwiftUI content fills whatever it is given.
        host.sizingOptions = []
        panel.contentView = host
        applyMinSize(to: panel)
        panel.setFrameOrigin(initialOrigin(for: size))

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidResize() }
        }

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

    /// Remembers a size the user dragged to, per mode (not the
    /// animation steps of expanding/collapsing).
    private func panelDidResize() {
        guard let panel else { return }
        size = panel.frame.size
        if panel.inLiveResize {
            UserDefaults.standard.set(NSStringFromSize(panel.frame.size),
                                      forKey: isExpanded ? Key.expandedSize : Key.compactSize)
            saveOrigin()
        }
    }

    /// Stored as left edge + top edge, so expanding/collapsing keeps the same anchor.
    private func saveOrigin() {
        guard let frame = panel?.frame else { return }
        let defaults = UserDefaults.standard
        defaults.set(frame.minX, forKey: Key.originX)
        defaults.set(frame.maxY, forKey: Key.topY)
    }
}
