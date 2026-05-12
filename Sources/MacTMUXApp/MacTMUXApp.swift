import AppKit
import SwiftUI

@main
struct MacTMUXApp: App {
    @NSApplicationDelegateAdaptor(MacTMUXAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class MacTMUXAppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: MacTMUXAppDelegate?

    private let store = MacTMUXStore()
    private var statusBarController: StatusBarController?
    private var isExplicitFullQuitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        statusBarController = StatusBarController(store: store)
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
