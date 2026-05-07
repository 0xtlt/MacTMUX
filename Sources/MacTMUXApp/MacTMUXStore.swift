import AppKit
import MacTMUXCore
import SwiftUI

@MainActor
final class MacTMUXStore: ObservableObject {
    @AppStorage("tmuxBinaryPath") private var configuredTmuxPath = ""
    @AppStorage("refreshInterval") var refreshInterval = 5.0

    @Published private(set) var sessions: [TmuxSession] = []
    @Published private(set) var selectedSession: TmuxSession?
    @Published private(set) var selectedLogs = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingLogs = false
    @Published var errorMessage: String?

    private let client = TmuxClient()
    private let terminalLauncher = TerminalAppLauncher()
    private var refreshLoopStarted = false

    init() {
        Task {
            await refresh()
            await startRefreshLoop()
        }
    }

    var compactSessions: [TmuxSession] {
        Array(sessions.prefix(5))
    }

    var tmuxPath: String? {
        let trimmed = configuredTmuxPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return TmuxPathResolver.autodetect()
    }

    var tmuxPathSetting: String {
        get {
            configuredTmuxPath
        }
        set {
            configuredTmuxPath = newValue
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        guard let tmuxPath else {
            sessions = []
            errorMessage = MacTMUXError.tmuxNotFound.localizedDescription
            return
        }

        guard TmuxPathResolver.isValidTmuxBinary(tmuxPath) else {
            sessions = []
            errorMessage = MacTMUXError.invalidTmuxPath(tmuxPath).localizedDescription
            return
        }

        do {
            sessions = try await loadSessions(tmuxPath: tmuxPath)
            if let selectedSession, !sessions.contains(where: { $0.id == selectedSession.id }) {
                self.selectedSession = nil
                selectedLogs = ""
            }
            errorMessage = nil
        } catch {
            sessions = []
            errorMessage = readableMessage(error)
        }
    }

    func open(_ session: TmuxSession) async {
        do {
            try await terminalLauncher.open(session: session)
            errorMessage = nil
        } catch {
            errorMessage = readableMessage(error)
        }
    }

    func select(_ session: TmuxSession) async {
        selectedSession = session
        await loadLogs(for: session)
    }

    func loadLogs(for session: TmuxSession) async {
        isLoadingLogs = true
        defer {
            isLoadingLogs = false
        }

        do {
            selectedLogs = try await client.captureLogs(session: session)
            errorMessage = nil
        } catch {
            selectedLogs = ""
            errorMessage = readableMessage(error)
        }
    }

    func stop(_ session: TmuxSession) async {
        guard confirm(title: "Stop \(session.name)?", message: "This will kill the selected tmux session.") else {
            return
        }

        do {
            try await client.stop(session: session)
            await refresh()
        } catch {
            errorMessage = readableMessage(error)
        }
    }

    func restart(_ session: TmuxSession) async {
        guard confirm(title: "Restart \(session.name)?", message: "This will respawn the active pane in the selected tmux session.") else {
            return
        }

        do {
            try await client.restartActivePane(session: session)
            await loadLogs(for: session)
            errorMessage = nil
        } catch {
            errorMessage = readableMessage(error)
        }
    }

    func resetTmuxPathToAutodetect() {
        configuredTmuxPath = ""
    }

    func startRefreshLoop() async {
        guard !refreshLoopStarted else {
            return
        }
        refreshLoopStarted = true

        while !Task.isCancelled {
            let seconds = max(2.0, refreshInterval)
            try? await Task.sleep(for: .seconds(seconds))
            await refresh()
        }
    }

    private func defaultSocketPath() -> String? {
        let uid = getuid()
        let path = "/tmp/tmux-\(uid)/default"
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    private func candidateServers(tmuxPath: String) -> [TmuxServer] {
        var servers: [TmuxServer] = []
        if let socketPath = defaultSocketPath() {
            servers.append(TmuxServer(binaryPath: tmuxPath, socketPath: socketPath))
        }
        servers.append(TmuxServer(binaryPath: tmuxPath))
        return servers
    }

    private func loadSessions(tmuxPath: String) async throws -> [TmuxSession] {
        var lastError: Error?
        for server in candidateServers(tmuxPath: tmuxPath) {
            do {
                let loadedSessions = try await client.listSessions(server: server)
                if !loadedSessions.isEmpty {
                    return loadedSessions
                }
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        return []
    }

    private func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func readableMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description.isEmpty ? "Unknown error." : description
        }
        return error.localizedDescription
    }
}
