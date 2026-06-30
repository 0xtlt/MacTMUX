import AppKit
import MacTMUXCore
import SwiftUI

@MainActor
final class AppWindowPresenter {
    static let shared = AppWindowPresenter()

    private var settingsWindow: NSWindow?
    private var sessionsWindow: NSWindow?
    private let windowCloseDelegate = WindowCloseDelegate {
        AppWindowPresenter.shared.updateActivationPolicyAfterWindowClose()
    }

    private init() {}

    var hasVisibleUserWindow: Bool {
        settingsWindow?.isVisible == true || sessionsWindow?.isVisible == true
    }

    func showSettings(store: MacTMUXStore) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacTMUX Settings"
            window.isReleasedWhenClosed = false
            window.delegate = windowCloseDelegate
            window.contentView = NSHostingView(
                rootView: SettingsView()
                    .environmentObject(store)
            )
            window.center()
            settingsWindow = window
        }

        show(window: settingsWindow)
    }

    func showSessions(store: MacTMUXStore, selecting session: TmuxSession? = nil) {
        if sessionsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacTMUX Sessions"
            window.titleVisibility = .visible
            window.isReleasedWhenClosed = false
            window.delegate = windowCloseDelegate
            window.contentView = NSHostingView(
                rootView: SessionsWindowView()
                    .environmentObject(store)
                    .frame(minWidth: 780, minHeight: 480)
            )
            window.center()
            sessionsWindow = window
        }

        Task {
            if let session {
                await store.select(session)
            } else {
                await store.refresh()
            }
        }
        show(window: sessionsWindow)
    }

    private func show(window: NSWindow?) {
        guard let window else {
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeUserWindowsAndReturnToMenuBar() {
        sessionsWindow?.close()
        settingsWindow?.close()
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func returnToMenuBarIfNoUserWindowsAreVisible() {
        if !hasVisibleUserWindow {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private func updateActivationPolicyAfterWindowClose() {
        returnToMenuBarIfNoUserWindowsAreVisible()
    }
}

@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [onClose] in
            onClose()
        }
    }
}
