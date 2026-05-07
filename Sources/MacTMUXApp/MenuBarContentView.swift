import AppKit
import MacTMUXCore
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var store: MacTMUXStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }

            if store.sessions.isEmpty {
                Text(store.isRefreshing ? "Refreshing..." : "No tmux sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.compactSessions) { session in
                    Button {
                        Task {
                            await store.open(session)
                        }
                    } label: {
                        HStack {
                            Text(session.name)
                            Spacer()
                            Text("\(session.windows)w")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if store.sessions.count > 5 {
                Divider()
                Button("Show all sessions...") {
                    openWindow(id: "sessions")
                }
            }

            Divider()

            Button(store.isRefreshing ? "Refreshing..." : "Refresh") {
                Task {
                    await store.refresh()
                }
            }
            .disabled(store.isRefreshing)

            Button("Settings...") {
                openSettings()
            }

            Button("Quit MacTMUX") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
