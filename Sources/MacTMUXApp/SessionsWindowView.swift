import MacTMUXCore
import SwiftUI

struct SessionsWindowView: View {
    @EnvironmentObject private var store: MacTMUXStore

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { store.selectedSession?.id },
                    set: { id in
                        guard let id, let session = store.sessions.first(where: { $0.id == id }) else {
                            return
                        }
                        Task {
                            await store.select(session)
                        }
                    }
                )) {
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
                                    Task {
                                        await store.restart(session)
                                    }
                                }
                                Button("Stop") {
                                    Task {
                                        await store.stop(session)
                                    }
                                }
                            }
                    }
                }

                HStack {
                    Button("Refresh") {
                        Task {
                            await store.refresh()
                        }
                    }
                    .disabled(store.isRefreshing)

                    Spacer()

                    Text("\(store.sessions.count) sessions")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .navigationTitle("Sessions")
            .frame(minWidth: 260)
        } detail: {
            if let session = store.selectedSession {
                SessionDetailView(session: session)
            } else {
                ContentUnavailableView("Select a session", systemImage: "terminal")
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)
                if session.attached {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                }
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [
            "\(session.windows) windows",
            "created \(session.createdAt.formatted(date: .abbreviated, time: .shortened))"
        ]
        if let metricsText = store.metricsText(for: session) {
            parts.append(metricsText)
        }
        return parts.joined(separator: " · ")
    }
}

private struct SessionDetailView: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(session.windows) windows · \(session.attached ? "attached" : "detached")")
                        .foregroundStyle(.secondary)
                    if let metricsText = store.metricsText(for: session) {
                        Text(metricsText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Open", systemImage: "terminal") {
                    Task {
                        await store.open(session)
                    }
                }

                Button("Restart", systemImage: "arrow.clockwise") {
                    Task {
                        await store.restart(session)
                    }
                }

                Button("Stop", systemImage: "power") {
                    Task {
                        await store.stop(session)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent Output")
                        .font(.headline)
                    Spacer()
                    Button("Reload") {
                        Task {
                            await store.loadLogs(for: session)
                        }
                    }
                    .disabled(store.isLoadingLogs)
                }

                ScrollView {
                    Text(store.isLoadingLogs ? "Loading..." : store.selectedLogs)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
        }
    }
}
