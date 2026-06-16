import MacTMUXCore
import SwiftUI

struct SessionsWindowView: View {
    @EnvironmentObject private var store: MacTMUXStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedSessionIDs = Set<String>()
    @State private var pendingConfirmation: SessionActionConfirmation?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionsSidebarView(
                selectedSessionIDs: $selectedSessionIDs,
                selectedSessions: selectedSessions,
                requestRestart: requestRestart,
                requestStop: requestStop,
                requestStopSelectedSessions: requestStopSelectedSessions
            )
            .navigationSplitViewColumnWidth(
                min: SidebarWidth.minimum,
                ideal: SidebarWidth.defaultValue,
                max: SidebarWidth.maximum
            )
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .padding(10)
                    .glassEffect(.regular.tint(.red.opacity(0.14)), in: RoundedRectangle(cornerRadius: 8))
                    .padding()
                }
        }
        .onAppear {
            columnVisibility = .all
            syncSelectionWithFocusedSession()
        }
        .onChange(of: selectedSessionIDs) { previousSelection, newSelection in
            focusSessionAfterSelectionChange(from: previousSelection, to: newSelection)
        }
        .onChange(of: sessionIDs) { _, _ in
            pruneSelectedSessionIDs()
        }
        .onChange(of: store.selectedSession?.id) { _, _ in
            syncSelectionWithFocusedSession()
        }
        .sessionActionConfirmation($pendingConfirmation, stoppedSessions: handleStoppedSessions)
    }

    private var detail: some View {
        Group {
            if let session = store.selectedSession {
                SessionDetailView(
                    session: session,
                    selectedSessions: selectedSessions,
                    requestRestart: requestRestart,
                    requestStop: requestStop,
                    requestStopSelectedSessions: requestStopSelectedSessions
                )
                .id(session.id)
            } else {
                ContentUnavailableView {
                    Label("Select a session", systemImage: "terminal")
                } description: {
                    Text("Choose a tmux session in the sidebar to inspect panes and logs.")
                } actions: {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            await store.refresh()
                        }
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedSessions: [TmuxSession] {
        store.sessions.filter { selectedSessionIDs.contains($0.id) }
    }

    private var sessionIDs: [String] {
        store.sessions.map(\.id)
    }

    private func focusSessionAfterSelectionChange(from previousSelection: Set<String>, to newSelection: Set<String>) {
        guard !newSelection.isEmpty else {
            Task { @MainActor in
                store.clearSelection()
            }
            return
        }

        let addedIDs = newSelection.subtracting(previousSelection)
        let focusID = store.sessions.first(where: { addedIDs.contains($0.id) })?.id
            ?? store.sessions.first(where: { newSelection.contains($0.id) })?.id

        guard let focusID, let session = store.sessions.first(where: { $0.id == focusID }) else {
            return
        }

        Task {
            await store.select(session)
        }
    }

    private func syncSelectionWithFocusedSession() {
        if let selectedSession = store.selectedSession {
            if selectedSessionIDs.isEmpty || !selectedSessionIDs.contains(selectedSession.id) {
                selectedSessionIDs = [selectedSession.id]
            }
        }
        pruneSelectedSessionIDs()
    }

    private func pruneSelectedSessionIDs() {
        let previousSelection = selectedSessionIDs
        let focusedID = store.selectedSession?.id
        let validSessionIDs = Set(sessionIDs)
        selectedSessionIDs.formIntersection(validSessionIDs)

        guard selectedSessionIDs != previousSelection else {
            return
        }

        if selectedSessionIDs.isEmpty || focusedID.map({ !selectedSessionIDs.contains($0) }) == true {
            focusSessionAfterSelectionChange(from: previousSelection, to: selectedSessionIDs)
        }
    }

    private func requestRestart(_ session: TmuxSession) {
        pendingConfirmation = .restart(session)
    }

    private func requestStop(_ session: TmuxSession) {
        pendingConfirmation = .stop([session])
    }

    private func requestStopSelectedSessions() {
        let sessionsToStop = selectedSessions
        guard !sessionsToStop.isEmpty else {
            return
        }

        pendingConfirmation = .stop(sessionsToStop)
    }

    private func handleStoppedSessions(_ stoppedIDs: Set<String>) {
        selectedSessionIDs.subtract(stoppedIDs)
        pruneSelectedSessionIDs()
    }
}
