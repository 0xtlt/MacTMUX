import AppKit
import MacTMUXCore
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    let store: MacTMUXStore
    @State private var snapshot = MenuBarSnapshot()

    var body: some View {
        Group {
            Button("Show All") {
                showSessions()
            }

            Button(snapshot.isRefreshing ? "Refreshing..." : "Refresh") {
                Task { @MainActor in
                    await store.refresh()
                    snapshot = MenuBarSnapshot(store: store)
                }
            }
            .disabled(snapshot.isRefreshing)

            Button("Settings...") {
                AppActivationController.presentUserWindow()
                openSettings()
            }

            Divider()

            if let errorMessage = snapshot.errorMessage {
                Text("Error: \(menuTitle(errorMessage))")
            }

            if snapshot.sessions.isEmpty {
                Text(snapshot.isRefreshing ? "Refreshing..." : "No tmux sessions")
            } else {
                Section("\(snapshot.sessions.count) \(snapshot.sessions.count == 1 ? "session" : "sessions")") {
                    ForEach(snapshot.compactSessions) { session in
                        sessionMenu(for: session)
                    }

                    if snapshot.hiddenSessionCount > 0 {
                        Button("\(snapshot.hiddenSessionCount) more...") {
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
            snapshot = MenuBarSnapshot(store: store)
            store.setMenuBarMenuPresented(true)
        }
        .onReceive(store.objectWillChange) { _ in
            Task { @MainActor in
                await Task.yield()
                refreshSnapshotIfSessionSummaryChanged()
            }
        }
        .onDisappear {
            store.setMenuBarMenuPresented(false)
        }
    }

    private func refreshSnapshotIfSessionSummaryChanged() {
        let currentSignature = MenuBarSnapshot.sessionSignature(for: store.sessions)
        guard currentSignature != snapshot.sessionSignature else {
            return
        }
        snapshot = MenuBarSnapshot(store: store)
    }

    @ViewBuilder
    private func sessionMenu(for session: TmuxSession) -> some View {
        Menu {
            Button("Open") {
                showSessions(selecting: session)
            }

            if !snapshot.recentLinks(for: session).isEmpty {
                linksMenu(for: session)
            }

            if let metricsText = snapshot.metricsText(for: session) {
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
            ForEach(snapshot.recentLinks(for: session)) { link in
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

struct MenuBarSnapshot {
    var sessions: [TmuxSession]
    var errorMessage: String?
    var isRefreshing: Bool
    private var recentLinksBySessionID: [String: [DetectedLogLink]]
    private var metricsTextBySessionID: [String: String]

    init(
        sessions: [TmuxSession] = [],
        errorMessage: String? = nil,
        isRefreshing: Bool = false,
        recentLinksBySessionID: [String: [DetectedLogLink]] = [:],
        metricsTextBySessionID: [String: String] = [:]
    ) {
        self.sessions = sessions
        self.errorMessage = errorMessage
        self.isRefreshing = isRefreshing
        self.recentLinksBySessionID = recentLinksBySessionID
        self.metricsTextBySessionID = metricsTextBySessionID
    }

    @MainActor
    init(store: MacTMUXStore) {
        let sessions = store.sessions
        self.sessions = sessions
        self.errorMessage = store.errorMessage
        self.isRefreshing = store.isRefreshing
        self.recentLinksBySessionID = Dictionary(
            uniqueKeysWithValues: sessions.map { session in
                (session.id, store.recentLinks(for: session))
            }
        )
        self.metricsTextBySessionID = Dictionary(
            uniqueKeysWithValues: sessions.compactMap { session in
                store.metricsText(for: session).map { (session.id, $0) }
            }
        )
    }

    var compactSessions: [TmuxSession] {
        Array(sessions.prefix(5))
    }

    var hiddenSessionCount: Int {
        max(0, sessions.count - compactSessions.count)
    }

    var sessionSignature: [String] {
        Self.sessionSignature(for: sessions)
    }

    static func sessionSignature(for sessions: [TmuxSession]) -> [String] {
        sessions.map { session in
            "\(session.id)|\(session.name)|\(session.windows)"
        }
    }

    func recentLinks(for session: TmuxSession) -> [DetectedLogLink] {
        recentLinksBySessionID[session.id] ?? []
    }

    func metricsText(for session: TmuxSession) -> String? {
        metricsTextBySessionID[session.id]
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
        let hadVisibleUserWindow = AppActivationController.hasVisibleUserWindow
        AppActivationController.presentUserWindow()

        defer {
            if !hadVisibleUserWindow {
                AppActivationController.returnToMenuBarIfNoUserWindowsAreVisible()
            }
        }

        let alert = makeAlert(for: confirmation)
        prepareAlertWindowForForeground(alert.window)

        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func makeAlert(for confirmation: SessionActionConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmation.confirmationTitle)
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    @MainActor
    private static func prepareAlertWindowForForeground(_ window: NSWindow) {
        window.level = .modalPanel
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
