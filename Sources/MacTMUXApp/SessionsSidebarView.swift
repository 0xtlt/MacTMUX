import MacTMUXCore
import SwiftUI

struct SessionsSidebarView: View {
    @EnvironmentObject private var store: MacTMUXStore
    @Binding var selectedSessionIDs: Set<String>
    var selectedSessions: [TmuxSession]
    var requestRestart: (TmuxSession) -> Void
    var requestStop: (TmuxSession) -> Void
    var requestStopSelectedSessions: () -> Void

    var body: some View {
        List(selection: $selectedSessionIDs) {
            ForEach(store.sessions) { session in
                SessionRow(session: session)
                    .tag(session.id)
                    .contextMenu {
                        Button("Open") {
                            Task {
                                await store.open(session)
                            }
                        }
                        Button("Restart") {
                            requestRestart(session)
                        }
                        Button("Stop", role: .destructive) {
                            requestStop(session)
                        }
                        if selectedSessions.count > 1, selectedSessionIDs.contains(session.id) {
                            Divider()
                            Button("Stop \(selectedSessions.count) Selected", role: .destructive) {
                                requestStopSelectedSessions()
                            }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    Task {
                        await store.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .controlSize(.small)
                .labelStyle(.iconOnly)
                .help("Refresh sessions")

                Spacer()

                Text("\(store.sessions.count) \(store.sessions.count == 1 ? "session" : "sessions")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Divider()
                    .opacity(0.35)
            }
        }
    }
}

enum SidebarWidth {
    static let defaultValue: CGFloat = 280
    static let minimum: CGFloat = 220
    static let maximum: CGFloat = 360
}

private struct SessionRow: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.attached ? "terminal.fill" : "terminal")
                .foregroundStyle(session.attached ? .primary : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let metricsText = store.metricsText(for: session) {
            parts.append(metricsText)
        }
        return parts.joined(separator: " · ")
    }
}
