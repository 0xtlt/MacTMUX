import AppKit

@MainActor
enum AppActivationController {
    static var didResignActiveNotification: Notification.Name {
        NSApplication.didResignActiveNotification
    }

    static let openSessionsWindowNotification = Notification.Name("MacTMUXOpenSessionsWindowNotification")

    static func presentUserWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static var hasVisibleUserWindow: Bool {
        NSApplication.shared.windows.contains { window in
            window.isVisible && window.title.hasPrefix("MacTMUX")
        }
    }

    static func requestSessionsWindow() {
        NotificationCenter.default.post(name: openSessionsWindowNotification, object: nil)
    }

    static func returnToMenuBarIfNoUserWindowsAreVisible() {
        if !hasVisibleUserWindow {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    static func terminate() {
        NSApplication.shared.terminate(nil)
    }
}
