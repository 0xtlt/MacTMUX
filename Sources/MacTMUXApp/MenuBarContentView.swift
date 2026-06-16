import AppKit
import MacTMUXCore
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: MacTMUXStore

    var body: some View {
        Group {
            Button("Show All") {
                showSessions()
            }

            Button(store.isRefreshing ? "Refreshing..." : "Refresh") {
                Task {
                    await store.refresh()
                }
            }
            .disabled(store.isRefreshing)

            Button("Settings...") {
                AppActivationController.presentUserWindow()
                openSettings()
            }

            Divider()

            if let errorMessage = store.errorMessage {
                Text("Error: \(menuTitle(errorMessage))")
            }

            if store.sessions.isEmpty {
                Text(store.isRefreshing ? "Refreshing..." : "No tmux sessions")
            } else {
                Section("\(store.sessions.count) \(store.sessions.count == 1 ? "session" : "sessions")") {
                    ForEach(store.compactSessions) { session in
                        sessionMenu(for: session)
                    }

                    if hiddenSessionCount > 0 {
                        Button("\(hiddenSessionCount) more...") {
                            showSessions()
                        }
                    }
                }
            }

            Divider()

            Button("Quit MacTMUX") {
                AppActivationController.terminate()
            }
        }
        .onAppear {
            store.setMenuBarMenuPresented(true)
        }
        .onDisappear {
            store.setMenuBarMenuPresented(false)
        }
    }

    private var hiddenSessionCount: Int {
        max(0, store.sessions.count - store.compactSessions.count)
    }

    @ViewBuilder
    private func sessionMenu(for session: TmuxSession) -> some View {
        Menu {
            Button("Open") {
                showSessions(selecting: session)
            }

            if !store.recentLinks(for: session).isEmpty {
                linksMenu(for: session)
            }

            if let metricsText = store.metricsText(for: session) {
                Divider()
                Text(metricsText)
            }

            Divider()

            Button("Restart") {
                confirmAndPerform(.restart(session))
            }

            Button("Stop", role: .destructive) {
                confirmAndPerform(.stop([session]))
            }
        } label: {
            Label(MenuBarSessionTitleFormatter.title(for: session.name), systemImage: "terminal")
        }
    }

    @ViewBuilder
    private func linksMenu(for session: TmuxSession) -> some View {
        Menu("Links") {
            ForEach(store.recentLinks(for: session)) { link in
                Button(LinkMenuTitleFormatter.title(for: link.displayText)) {
                    open(link)
                }
            }
        }
    }

    private func showSessions() {
        AppActivationController.presentUserWindow()
        Task {
            await store.refresh()
            openWindow(id: MacTMUXWindowID.sessions)
            AppActivationController.presentUserWindow()
        }
    }

    private func showSessions(selecting session: TmuxSession) {
        AppActivationController.presentUserWindow()
        Task {
            await store.select(session)
            openWindow(id: MacTMUXWindowID.sessions)
            AppActivationController.presentUserWindow()
        }
    }

    private func open(_ link: DetectedLogLink) {
        guard let url = link.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        openURL(url)
    }

    private func menuTitle(_ value: String) -> String {
        MenuBarSessionTitleFormatter.title(for: value)
    }

    private func confirmAndPerform(_ confirmation: SessionActionConfirmation) {
        guard AppKitSessionActionConfirmer.confirm(confirmation) else {
            return
        }

        Task {
            switch confirmation {
            case .restart(let session):
                await store.restart(session)
            case .stop(let sessions):
                _ = await store.stopSessions(sessions)
            }
        }
    }
}

enum MenuBarSessionTitleFormatter {
    static let maximumLength = 30

    static func title(for value: String) -> String {
        guard value.count > maximumLength else {
            return value
        }

        return "\(value.prefix(maximumLength - 3))..."
    }
}

private enum AppKitSessionActionConfirmer {
    @MainActor
    static func confirm(_ confirmation: SessionActionConfirmation) -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmation.confirmationTitle)
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }
}
