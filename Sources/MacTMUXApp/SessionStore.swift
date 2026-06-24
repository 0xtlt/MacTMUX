import MacTMUXCore
import Foundation

struct SessionRefreshResult {
    var sessions: [TmuxSession]
    var removedSelectedSession: Bool
}

@MainActor
final class SessionStore {
    private let client: any TmuxClientProviding
    private var notifyChange: () -> Void

    private(set) var sessions: [TmuxSession] = []
    private(set) var panesBySessionID: [String: [TmuxPane]] = [:]
    private(set) var selectedPaneBySessionID: [String: TmuxPane] = [:]
    private(set) var selectedSession: TmuxSession?

    init(client: any TmuxClientProviding, notifyChange: @escaping () -> Void = {}) {
        self.client = client
        self.notifyChange = notifyChange
    }

    func setNotifyChange(_ notifyChange: @escaping () -> Void) {
        self.notifyChange = notifyChange
    }

    var compactSessions: [TmuxSession] {
        Array(sessions.prefix(5))
    }

    var selectedPane: TmuxPane? {
        guard let selectedSession else {
            return nil
        }
        return selectedPane(for: selectedSession)
    }

    func panes(for session: TmuxSession) -> [TmuxPane] {
        panesBySessionID[session.id] ?? []
    }

    func clearAll() {
        sessions = []
        panesBySessionID = [:]
        selectedPaneBySessionID = [:]
        selectedSession = nil
        notifyChange()
    }

    func refresh(tmuxPath: String) async throws -> SessionRefreshResult {
        let previousSelectedSessionID = selectedSession?.id
        let loadedSessions = try await loadSessions(tmuxPath: tmuxPath)
        sessions = loadedSessions
        await loadPanes(for: loadedSessions)

        var removedSelectedSession = false
        if let selectedSession {
            if let refreshedSelection = loadedSessions.first(where: { $0.id == selectedSession.id }) {
                self.selectedSession = refreshedSelection
                selectDefaultPaneIfNeeded(for: refreshedSelection)
            } else {
                self.selectedSession = nil
                removedSelectedSession = true
            }
        }

        if previousSelectedSessionID != selectedSession?.id {
            removedSelectedSession = removedSelectedSession || previousSelectedSessionID != nil
        }

        notifyChange()
        return SessionRefreshResult(sessions: loadedSessions, removedSelectedSession: removedSelectedSession)
    }

    func select(_ session: TmuxSession) async -> Bool {
        let changedSelection = selectedSession?.id != session.id
        selectedSession = session
        await loadPanesIfNeeded(for: session)
        selectDefaultPaneIfNeeded(for: session)
        notifyChange()
        return changedSelection
    }

    func selectPane(_ pane: TmuxPane, for session: TmuxSession) -> Bool {
        guard pane.sessionID == session.id else {
            return false
        }

        let changedPane = selectedPaneBySessionID[session.id]?.id != pane.id
        if changedPane {
            selectedPaneBySessionID[session.id] = pane
        }
        selectedSession = session
        notifyChange()
        return changedPane
    }

    func clearSelection() {
        selectedSession = nil
        notifyChange()
    }

    func selectedPane(for session: TmuxSession) -> TmuxPane? {
        if let pane = selectedPaneBySessionID[session.id] {
            return pane
        }
        return panesBySessionID[session.id]?.first
    }

    private func defaultSocketPath() -> String? {
        let uid = getuid()
        let path = "/tmp/tmux-\(uid)/default"
        guard FileManager.default.fileExists(atPath: path) else {
            DiagnosticLog.write("default socket missing path=\(path)")
            return nil
        }
        DiagnosticLog.write("default socket found path=\(path)")
        return path
    }

    private func candidateServers(tmuxPath: String) -> [TmuxServer] {
        var servers: [TmuxServer] = []
        if let socketPath = defaultSocketPath() {
            servers.append(TmuxServer(binaryPath: tmuxPath, socketPath: socketPath))
        }
        servers.append(TmuxServer(binaryPath: tmuxPath))
        DiagnosticLog.write("candidate servers count=\(servers.count) values=\(servers)")
        return servers
    }

    private func loadSessions(tmuxPath: String) async throws -> [TmuxSession] {
        var lastError: Error?
        for server in candidateServers(tmuxPath: tmuxPath) {
            do {
                DiagnosticLog.write("load sessions trying server=\(server)")
                let loadedSessions = try await client.listSessions(server: server)
                if !loadedSessions.isEmpty {
                    DiagnosticLog.write("load sessions success count=\(loadedSessions.count) server=\(server)")
                    return loadedSessions
                }
                DiagnosticLog.write("load sessions empty server=\(server)")
            } catch {
                lastError = error
                DiagnosticLog.write("load sessions failed server=\(server) error=\(readableMessage(error))")
            }
        }
        if let lastError {
            throw lastError
        }
        return []
    }

    private func loadPanes(for sessions: [TmuxSession]) async {
        let validSessionIDs = Set(sessions.map(\.id))
        var nextPanesBySessionID = panesBySessionID.filter { validSessionIDs.contains($0.key) }
        var nextSelectedPaneBySessionID = selectedPaneBySessionID.filter { validSessionIDs.contains($0.key) }

        guard !sessions.isEmpty else {
            panesBySessionID = [:]
            selectedPaneBySessionID = [:]
            return
        }

        let client = self.client
        let loadedPanes = await withTaskGroup(of: (TmuxSession, [TmuxPane]?).self) { group in
            for session in sessions {
                group.addTask {
                    do {
                        return (session, try await client.listPanes(session: session))
                    } catch {
                        DiagnosticLog.write("list panes failed session=\(session.name) error=\(error.localizedDescription)")
                        return (session, nil)
                    }
                }
            }

            var result: [(TmuxSession, [TmuxPane]?)] = []
            for await panes in group {
                result.append(panes)
            }
            return result
        }

        for (session, panes) in loadedPanes {
            guard let panes else {
                continue
            }

            nextPanesBySessionID[session.id] = panes
            if let selectedPane = nextSelectedPaneBySessionID[session.id],
               let refreshedPane = panes.first(where: { $0.id == selectedPane.id }) {
                nextSelectedPaneBySessionID[session.id] = refreshedPane
            } else {
                nextSelectedPaneBySessionID[session.id] = panes.first
            }
        }

        panesBySessionID = nextPanesBySessionID
        selectedPaneBySessionID = nextSelectedPaneBySessionID
    }

    private func loadPanesIfNeeded(for session: TmuxSession) async {
        guard panesBySessionID[session.id]?.isEmpty != false else {
            return
        }

        do {
            let panes = try await client.listPanes(session: session)
            panesBySessionID[session.id] = panes
            selectedPaneBySessionID[session.id] = panes.first
        } catch {
            panesBySessionID[session.id] = []
            selectedPaneBySessionID.removeValue(forKey: session.id)
            DiagnosticLog.write("list panes failed session=\(session.name) error=\(readableMessage(error))")
        }
    }

    private func selectDefaultPaneIfNeeded(for session: TmuxSession) {
        let panes = panesBySessionID[session.id] ?? []
        if let selectedPane = selectedPaneBySessionID[session.id],
           panes.contains(where: { $0.id == selectedPane.id }) {
            return
        }
        selectedPaneBySessionID[session.id] = panes.first
    }

    private func readableMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description.isEmpty ? "Unknown error." : description
        }
        return error.localizedDescription
    }
}
