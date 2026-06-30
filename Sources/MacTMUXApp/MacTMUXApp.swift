import AppKit
import SwiftUI

@main
struct MacTMUXApp: App {
    @NSApplicationDelegateAdaptor(MacTMUXApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MacTMUXApplicationDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: MacTMUXApplicationDelegate?

    let store = MacTMUXStore()
    private var statusBarController: StatusBarController?
    private var isExplicitFullQuitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApplication.shared.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(store: store)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindowPresenter.shared.showSessions(store: store)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isExplicitFullQuitRequested else {
            AppWindowPresenter.shared.closeUserWindowsAndReturnToMenuBar()
            return .terminateCancel
        }

        return .terminateNow
    }

    func requestFullQuit() {
        isExplicitFullQuitRequested = true
        NSApplication.shared.terminate(nil)
    }
}
