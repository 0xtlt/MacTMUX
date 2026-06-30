import AppKit
import MacTMUXCore
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var store: MacTMUXStore
    @State private var snapshot = MenuBarSnapshot()

    var body: some View {
        VStack(spacing: 0) {
            header

            if let errorMessage = snapshot.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            sessionsList

            Divider()
                .padding(.top, 10)

            footer
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text("MacTMUX")
                    .font(.headline)
                Text("\(snapshot.sessions.count) \(snapshot.sessions.count == 1 ? "session" : "sessions")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            iconButton("Refresh", systemImage: snapshot.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise") {
                Task {
                    await store.refresh()
                    snapshot = MenuBarSnapshot(store: store)
                }
            }
            .disabled(snapshot.isRefreshing)

            iconButton("Settings", systemImage: "gearshape") {
                AppWindowPresenter.shared.showSettings(store: store)
            }
        }
        .padding(12)
    }

    private var sessionsList: some View {
        VStack(spacing: 8) {
            if snapshot.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(snapshot.isRefreshing ? "Refreshing..." : "No tmux sessions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 112)
            } else {
                ForEach(snapshot.compactSessions) { session in
                    MenuSessionRow(
                        session: session,
                        links: snapshot.recentLinks(for: session),
                        metricsText: snapshot.metricsText(for: session)
                    )
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                showSessions()
            } label: {
                Label("Show All", systemImage: "sidebar.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                AppActivationController.terminate()
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
    }

    private func iconButton(_ help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.08))
        )
        .help(help)
    }

    private func refreshSnapshotIfSessionSummaryChanged() {
        let currentSignature = MenuBarSnapshot.sessionSignature(for: store.sessions)
        guard currentSignature != snapshot.sessionSignature else {
            return
        }
        snapshot = MenuBarSnapshot(store: store)
    }

    private func showSessions() {
        AppWindowPresenter.shared.showSessions(store: store)
    }
}

private struct MenuSessionRow: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession
    var links: [DetectedLogLink]
    var metricsText: String?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                AppWindowPresenter.shared.showSessions(store: store, selecting: session)
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color.green.opacity(0.25), lineWidth: 3)
                        )
                        .help("Running")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SessionLinksControl(links: links)

            Button {
                confirmAndPerform(.restart(session))
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Restart")

            Button {
                confirmAndPerform(.stop([session]))
            } label: {
                Image(systemName: "power")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Stop")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.07))
        )
    }

    private var subtitle: String {
        var parts = [
            session.createdAt.formatted(date: .omitted, time: .shortened)
        ]
        if let metricsText {
            parts.append(metricsText)
        }
        return parts.joined(separator: " · ")
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
