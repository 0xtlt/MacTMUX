import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var isUnavailable: Bool {
        status == .notFound
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    var shouldShowLoginItemsButton: Bool {
        needsApproval || isUnavailable
    }

    var statusText: String {
        switch status {
        case .enabled:
            return "MacTMUX will start automatically when you log in."
        case .notRegistered:
            return "MacTMUX will stay menu-bar only unless opened manually."
        case .requiresApproval:
            return "macOS requires approval in Login Items before MacTMUX can launch at login."
        case .notFound:
            return "macOS could not find this app as a login item."
        @unknown default:
            return "macOS returned an unknown Login Items state."
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = readableMessage(error)
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func readableMessage(_ error: Error) -> String {
        let message = (error as NSError).localizedDescription
        if message.isEmpty {
            return "macOS refused to update Launch at Login."
        }
        return message
    }
}
