import Foundation
import ServiceManagement

/// Registers HyperDock to start at login.
///
/// `SMAppService.mainApp` works for an ad-hoc signed build — verified moving through
/// `notFound → enabled → notRegistered` with no prompt and no Developer ID.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("HyperDock: could not \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }
}
