import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginController {
    private static let configuredKey = "DevOnCall.launchAtLoginConfigured.v1"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func enableByDefaultOnce() {
        guard UserDefaults.standard.object(forKey: configuredKey) == nil else { return }

        do {
            try setEnabled(true)
        } catch {
            NSLog("Dev On Call could not enable launch at login: %@", error.localizedDescription)
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
        UserDefaults.standard.set(true, forKey: configuredKey)
    }
}
