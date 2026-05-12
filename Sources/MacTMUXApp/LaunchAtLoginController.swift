import Combine
import Darwin
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    @Published private(set) var usesLaunchAgentFallback: Bool

    private let launchAgent = LaunchAgentLoginItem()

    init() {
        status = .notRegistered
        usesLaunchAgentFallback = false
        refresh()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var isUnavailable: Bool {
        false
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    var shouldShowLoginItemsButton: Bool {
        needsApproval
    }

    var statusText: String {
        switch status {
        case .enabled:
            return "MacTMUX will start automatically when you log in."
        case .notRegistered:
            if usesLaunchAgentFallback {
                return "MacTMUX can launch at login using a local user login agent."
            }
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
        let serviceStatus = SMAppService.mainApp.status
        if serviceStatus == .notFound {
            usesLaunchAgentFallback = true
            status = launchAgent.isEnabled ? .enabled : .notRegistered
        } else {
            usesLaunchAgentFallback = false
            status = serviceStatus
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if SMAppService.mainApp.status == .notFound {
                try launchAgent.setEnabled(enabled)
            } else {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
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

private struct LaunchAgentLoginItem {
    private let label = "com.0xtlt.mactmux.loginitem"

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private func enable() throws {
        guard let executablePath = Bundle.main.executablePath else {
            throw LaunchAgentError.missingExecutablePath
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private func disable() throws {
        _ = try? runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistURL.path])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private func runLaunchctl(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchAgentError.launchctlFailed(message ?? "launchctl failed")
        }
    }
}

private enum LaunchAgentError: LocalizedError {
    case missingExecutablePath
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutablePath:
            return "MacTMUX could not find its executable path."
        case .launchctlFailed(let message):
            return message
        }
    }
}
