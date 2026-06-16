import AppKit
import SwiftUI

@main
struct MacTMUXApp: App {
    @NSApplicationDelegateAdaptor(MacTMUXApplicationDelegate.self) private var applicationDelegate
    @AppStorage("showMenuBarSessionCount") private var showMenuBarSessionCount = true
    @StateObject private var store = MacTMUXStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(store)
        } label: {
            MenuBarStatusLabel(sessionCount: store.sessions.count, showsSessionCount: showMenuBarSessionCount)
                .background {
                    SessionsWindowOpenRequestHandler(store: store)
                }
        }
        .menuBarExtraStyle(.menu)

        Window("MacTMUX Sessions", id: MacTMUXWindowID.sessions) {
            SessionsWindowView()
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 480)
        }
        .defaultSize(width: 840, height: 560)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

enum MacTMUXWindowID {
    static let sessions = "sessions"
}

final class MacTMUXApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppActivationController.hasVisibleUserWindow {
            AppActivationController.presentUserWindow()
        } else {
            AppActivationController.requestSessionsWindow()
        }

        return false
    }
}

private struct MenuBarStatusLabel: View {
    var sessionCount: Int
    var showsSessionCount: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "terminal")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 26, height: 20)

            if let badgeText = StatusBarBadgeFormatter.badgeText(
                sessionCount: sessionCount,
                showsSessionCount: showsSessionCount
            ) {
                Text(badgeText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, badgeText.count > 1 ? 4 : 3)
                    .frame(minWidth: 13, minHeight: 13)
                    .background(.red, in: Capsule())
                    .offset(x: 5, y: -5)
            }
        }
        .frame(width: 30, height: 22)
        .help(StatusBarBadgeFormatter.toolTip(sessionCount: sessionCount))
        .accessibilityLabel(StatusBarBadgeFormatter.toolTip(sessionCount: sessionCount))
    }
}

private struct SessionsWindowOpenRequestHandler: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: MacTMUXStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: AppActivationController.openSessionsWindowNotification)) { _ in
                openSessionsWindow()
            }
    }

    private func openSessionsWindow() {
        AppActivationController.presentUserWindow()
        Task {
            await store.refresh()
            openWindow(id: MacTMUXWindowID.sessions)
            AppActivationController.presentUserWindow()
        }
    }
}
