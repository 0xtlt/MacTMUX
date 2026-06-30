import AppKit

@MainActor
enum AppActivationController {
    static var didResignActiveNotification: Notification.Name {
        NSApplication.didResignActiveNotification
    }

    static let openSessionsWindowNotification = Notification.Name("MacTMUXOpenSessionsWindowNotification")

    static func presentUserWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    static var hasVisibleUserWindow: Bool {
        AppWindowPresenter.shared.hasVisibleUserWindow
    }

    static func requestSessionsWindow() {
        if let store = MacTMUXApplicationDelegate.shared?.store {
            AppWindowPresenter.shared.showSessions(store: store)
        } else {
            NotificationCenter.default.post(name: openSessionsWindowNotification, object: nil)
        }
    }

    static func returnToMenuBarIfNoUserWindowsAreVisible() {
        AppWindowPresenter.shared.returnToMenuBarIfNoUserWindowsAreVisible()
    }

    static func terminate() {
        if let applicationDelegate = MacTMUXApplicationDelegate.shared {
            applicationDelegate.requestFullQuit()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }
}
