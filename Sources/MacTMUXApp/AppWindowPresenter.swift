import AppKit
import SwiftUI

@MainActor
final class AppWindowPresenter {
    static let shared = AppWindowPresenter()

    private var settingsWindow: NSWindow?
    private var sessionsWindow: NSWindow?

    private init() {}

    func showSettings(store: MacTMUXStore) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacTMUX Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SettingsView()
                    .environmentObject(store)
            )
            window.center()
            settingsWindow = window
        }

        show(window: settingsWindow)
    }

    func showSessions(store: MacTMUXStore) {
        if sessionsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacTMUX Sessions"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SessionsWindowView()
                    .environmentObject(store)
                    .frame(minWidth: 780, minHeight: 480)
            )
            window.center()
            sessionsWindow = window
        }

        Task {
            await store.refresh()
        }
        show(window: sessionsWindow)
    }

    private func show(window: NSWindow?) {
        guard let window else {
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
