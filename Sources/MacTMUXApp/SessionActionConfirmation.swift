import MacTMUXCore
import SwiftUI

enum SessionActionConfirmation: Identifiable, Equatable {
    case restart(TmuxSession)
    case stop([TmuxSession])

    var id: String {
        switch self {
        case .restart(let session):
            return "restart-\(session.id)"
        case .stop(let sessions):
            return "stop-\(sessions.map(\.id).sorted().joined(separator: "|"))"
        }
    }

    var title: String {
        switch self {
        case .restart(let session):
            return "Restart \(session.name)?"
        case .stop(let sessions):
            return sessions.count == 1 ? "Stop \(sessions[0].name)?" : "Stop \(sessions.count) Sessions?"
        }
    }

    var message: String {
        switch self {
        case .restart:
            return "This will respawn the active pane in the selected tmux session."
        case .stop(let sessions):
            return stopMessage(for: sessions)
        }
    }

    var confirmationTitle: String {
        switch self {
        case .restart:
            return "Restart"
        case .stop(let sessions):
            return sessions.count == 1 ? "Stop" : "Stop \(sessions.count)"
        }
    }

    private func stopMessage(for sessions: [TmuxSession]) -> String {
        let prefix = sessions.count == 1
            ? "This will kill the selected tmux session."
            : "This will kill the selected tmux sessions."
        let shownNames = sessions.prefix(8).map { "- \($0.name)" }.joined(separator: "\n")
        let remainingCount = sessions.count - 8
        let remainingText = remainingCount > 0 ? "\nand \(remainingCount) more." : ""
        return "\(prefix)\n\n\(shownNames)\(remainingText)"
    }
}

private struct SessionActionConfirmationModifier: ViewModifier {
    @EnvironmentObject private var store: MacTMUXStore
    @Binding var confirmation: SessionActionConfirmation?
    var stoppedSessions: (Set<String>) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                confirmation?.title ?? "",
                isPresented: isConfirmationPresented,
                titleVisibility: .visible
            ) {
                if let confirmation {
                    Button(confirmation.confirmationTitle, role: .destructive) {
                        Task {
                            await perform(confirmation)
                        }
                    }
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                if let confirmation {
                    Text(confirmation.message)
                }
            }
    }

    private var isConfirmationPresented: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { isPresented in
                if !isPresented {
                    confirmation = nil
                }
            }
        )
    }

    @MainActor
    private func perform(_ confirmation: SessionActionConfirmation) async {
        switch confirmation {
        case .restart(let session):
            await store.restart(session)
        case .stop(let sessions):
            let stoppedIDs = await store.stopSessions(sessions)
            stoppedSessions(stoppedIDs)
        }
    }
}

extension View {
    func sessionActionConfirmation(
        _ confirmation: Binding<SessionActionConfirmation?>,
        stoppedSessions: @escaping (Set<String>) -> Void = { _ in }
    ) -> some View {
        modifier(SessionActionConfirmationModifier(
            confirmation: confirmation,
            stoppedSessions: stoppedSessions
        ))
    }
}
