import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (the modern, no-helper-app
/// replacement for the old `SMLoginItemSetEnabled`/LaunchAgent approach,
/// available since macOS 13 — well under our macOS 26 floor).
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[SoundCast][LaunchAtLogin] failed to \(enabled ? "register" : "unregister"): \(error)")
        }
    }
}
