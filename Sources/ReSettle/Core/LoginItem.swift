import Foundation
import ServiceManagement
import AppKit

enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static var statusDescription: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "On"
            case .notRegistered: return "Off"
            case .requiresApproval: return "Needs approval in System Settings"
            case .notFound: return "Not found (move app to /Applications)"
            @unknown default: return "Unknown"
            }
        }
        return "Unsupported"
    }

    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard #available(macOS 13.0, *) else { return "Requires macOS 13" }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            Log.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
