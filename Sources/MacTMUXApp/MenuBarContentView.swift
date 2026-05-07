import AppKit
import MacTMUXCore
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var store: MacTMUXStore

    var body: some View {
        VStack(spacing: 0) {
            header

            if let errorMessage = store.errorMessage {
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
                Text("\(store.sessions.count) \(store.sessions.count == 1 ? "session" : "sessions")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            iconButton("Refresh", systemImage: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise") {
                Task {
                    await store.refresh()
                }
            }
            .disabled(store.isRefreshing)

            iconButton("Settings", systemImage: "gearshape") {
                AppWindowPresenter.shared.showSettings(store: store)
            }
        }
        .padding(12)
    }

    private var sessionsList: some View {
        VStack(spacing: 8) {
            if store.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(store.isRefreshing ? "Refreshing..." : "No tmux sessions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 112)
            } else {
                ForEach(store.compactSessions) { session in
                    MenuSessionRow(session: session)
                        .environmentObject(store)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                AppWindowPresenter.shared.showSessions(store: store)
            } label: {
                Label("Show All", systemImage: "sidebar.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                NSApplication.shared.terminate(nil)
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
}

private struct MenuSessionRow: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await store.open(session)
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(session.attached ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text("\(session.windows) \(session.windows == 1 ? "window" : "windows") · \(session.createdAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    await store.restart(session)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Restart")

            Button {
                Task {
                    await store.stop(session)
                }
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
}
