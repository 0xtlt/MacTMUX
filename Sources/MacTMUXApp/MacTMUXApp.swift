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
    private let store = MacTMUXStore()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(store: store)
    }
}
