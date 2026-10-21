import Contacts2MdCLI
import Foundation
import Observation
import ServiceManagement

/// Launch at login (`SMAppService.mainApp`) and the background sync agent
/// (`SMAppService.agent(plistName:)`, one bundled plist per interval in
/// `Contents/Library/LaunchAgents`, see `UIBackgroundSync`). Settings ▸ General.
@MainActor
@Observable
final class BackgroundServices {
    private(set) var loginStatus: SMAppService.Status = .notRegistered
    private(set) var loginError: String?
    /// Hours of the registered background agent (`nil`: none).
    private(set) var agentHours: Int?
    private(set) var agentStatus: SMAppService.Status = .notRegistered
    private(set) var agentError: String?
    /// nix installs declare the schedule in nix-darwin instead.
    let install = UIBackgroundSync.install(bundlePath: Bundle.main.bundlePath)

    init() { refresh() }

    /// Re-reads both statuses (they change in System Settings too).
    func refresh() {
        loginStatus = SMAppService.mainApp.status
        agentHours = nil
        agentStatus = .notRegistered
        for hours in UIBackgroundSync.intervals {
            let status = Self.agent(hours).status
            if status == .enabled || status == .requiresApproval {
                agentHours = hours
                agentStatus = status
                break
            }
        }
    }

    var launchesAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Could not change Launch at login: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Registers the agent for `hours` (and unregisters the others), or
    /// unregisters every agent for `nil`.
    func setBackgroundSync(hours: Int?) {
        do {
            for other in UIBackgroundSync.intervals where other != hours {
                let service = Self.agent(other)
                if service.status != .notRegistered && service.status != .notFound { try service.unregister() }
            }
            if let hours, Self.agent(hours).status != .enabled { try Self.agent(hours).register() }
            agentError = nil
        } catch {
            agentError = "Could not change background sync: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    private static func agent(_ hours: Int) -> SMAppService {
        SMAppService.agent(plistName: UIBackgroundSync.plistName(hours: hours))
    }

    /// Status text for the settings row.
    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "On"
        case .requiresApproval: "Waiting for your approval in System Settings ▸ General ▸ Login Items"
        case .notRegistered: "Off"
        case .notFound: "Not available in this build of the app"
        @unknown default: "Unknown"
        }
    }
}
