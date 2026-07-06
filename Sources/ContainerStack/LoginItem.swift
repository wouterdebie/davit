import Foundation
import ServiceManagement

/// "Open at login" backed by SMAppService.mainApp (macOS 13+). Registering adds
/// Davit to the user's Login Items; the app launches to the menu bar at login.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
