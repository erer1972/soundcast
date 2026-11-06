import SwiftUI
import SoundCastCore

@main
struct SoundCastApp: App {
    @StateObject private var state: AppState
    @StateObject private var panel: FloatingPanelController

    /// True if an older SoundCast process is already running. Two copies
    /// would fight over the shared-memory rings, the audio devices and
    /// the menu bar, so a newer one quits immediately. If two start at
    /// the same moment, only the one that launched later exits.
    private static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { other in
            guard other.processIdentifier != me.processIdentifier, !other.isTerminated else { return false }
            guard let theirs = other.launchDate, let mine = me.launchDate else { return true }
            return theirs <= mine
        }
    }

    init() {
        if Self.anotherInstanceIsRunning() {
            NSLog("[SoundCast] Another instance is already running; exiting this one.")
            exit(0)
        }
        CPUFeatureGuard.logAndGuard(context: "app launch")
        let appState = AppState()
        _state = StateObject(wrappedValue: appState)
        _panel = StateObject(wrappedValue: FloatingPanelController(state: appState))
    }

    var body: some Scene {
        MenuBarExtra("SoundCast", systemImage: "hifispeaker.and.homepod") {
            MenuBarContentView(state: state, panel: panel)
        }
        .menuBarExtraStyle(.window)
    }
}
