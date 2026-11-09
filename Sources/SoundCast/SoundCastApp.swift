import SwiftUI
import SoundCastCore

/// Defers quit until AirPlay sessions are torn down, so receivers
/// stop immediately instead of timing the session out, and turns
/// SIGTERM (`pkill`, logout) into the same clean quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var appState: AppState?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSLog("[SoundCast] SIGTERM received; quitting cleanly")
            NSApplication.shared.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

    /// Last stop on every quit path (also after the async shutdown):
    /// give the Mac its previous output back.
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        Self.appState?.restoreSystemOutput()
    }

    /// Set once shutdown has run (or timed out), so the re-issued
    /// terminate goes straight through.
    @MainActor private var readyToQuit = false

    /// `.terminateLater` can't be used here: while AppKit waits for the
    /// reply it runs the main run loop in a mode that doesn't drain the
    /// main queue, so main-actor shutdown work (and any timeout) never
    /// runs. Confirmed live: the app hung after SIGTERM. Instead, cancel
    /// this terminate, shut down normally, then terminate again.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSLog("[SoundCast] applicationShouldTerminate (casting: \(Self.appState?.isCasting ?? false), ready: \(readyToQuit))")
        guard !readyToQuit, let state = Self.appState, state.isCasting else { return .terminateNow }
        let quit = { @MainActor [weak self] in
            guard let self, !self.readyToQuit else { return }
            self.readyToQuit = true
            sender.terminate(nil)
        }
        Task { @MainActor in
            await state.shutdown()
            quit()
        }
        // Never hang quit on a stuck network call.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { quit() }
        return .terminateCancel
    }
}

@main
struct SoundCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
        appState.startWebControl()
        AppDelegate.appState = appState
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
