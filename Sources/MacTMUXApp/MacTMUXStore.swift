import AppKit
import MacTMUXCore
import SwiftUI

@MainActor
final class MacTMUXStore: ObservableObject {
    @AppStorage("tmuxBinaryPath") private var configuredTmuxPath = ""
    @AppStorage("terminalKind") private var terminalKindRaw = TerminalKind.terminalApp.rawValue
    @AppStorage("refreshInterval") var refreshInterval = 5.0
    @AppStorage("showResourceMetrics") private var showResourceMetricsRaw = true

    @Published private(set) var sessions: [TmuxSession] = []
    @Published private(set) var resourceMetricsBySessionID: [String: ProcessResourceMetrics] = [:]
    @Published private(set) var selectedSession: TmuxSession?
    @Published private(set) var selectedLogs = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingLogs = false
    @Published var errorMessage: String?

    private let client = TmuxClient()
    private let metricsClient = ProcessMetricsClient()
    private var refreshLoopStarted = false

    init() {
        DiagnosticLog.clear()
        DiagnosticLog.write("store init")
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

    var terminalKind: TerminalKind {
        get {
            TerminalKind(rawValue: terminalKindRaw) ?? .terminalApp
        }
        set {
            terminalKindRaw = newValue.rawValue
        }
    }

    var showResourceMetrics: Bool {
        get {
            showResourceMetricsRaw
        }
        set {
            showResourceMetricsRaw = newValue
            if !newValue {
                resourceMetricsBySessionID = [:]
            } else {
                Task {
                    await refresh()
                }
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            DiagnosticLog.write("refresh skipped already refreshing")
            return
        }
        isRefreshing = true
        DiagnosticLog.write("refresh start configuredTmuxPath=\(configuredTmuxPath)")
        defer {
            isRefreshing = false
            DiagnosticLog.write("refresh end sessions=\(sessions.count) error=\(errorMessage ?? "nil")")
        }

        guard let tmuxPath else {
            sessions = []
            errorMessage = MacTMUXError.tmuxNotFound.localizedDescription
            DiagnosticLog.write("tmux path not found")
            return
        }

        guard TmuxPathResolver.isValidTmuxBinary(tmuxPath) else {
            sessions = []
            errorMessage = MacTMUXError.invalidTmuxPath(tmuxPath).localizedDescription
            DiagnosticLog.write("invalid tmux path \(tmuxPath)")
            return
        }

        do {
            let loadedSessions = try await loadSessions(tmuxPath: tmuxPath)
            sessions = loadedSessions
            await loadResourceMetricsIfNeeded(for: loadedSessions)
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
            try await TerminalLauncher(kind: terminalKind).open(session: session)
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

    func metricsText(for session: TmuxSession) -> String? {
        guard showResourceMetrics, let metrics = resourceMetricsBySessionID[session.id] else {
            return nil
        }
        return "CPU \(metrics.formattedCPU) · RAM \(metrics.formattedMemory)"
    }

    func startRefreshLoop() async {
        guard !refreshLoopStarted else {
            DiagnosticLog.write("refresh loop already started")
            return
        }
        refreshLoopStarted = true
        DiagnosticLog.write("refresh loop started interval=\(refreshInterval)")

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

    private func loadResourceMetricsIfNeeded(for sessions: [TmuxSession]) async {
        guard showResourceMetrics else {
            resourceMetricsBySessionID = [:]
            return
        }

        let pidPairs = sessions.compactMap { session -> (String, Int32)? in
            guard let activePanePID = session.activePanePID else {
                return nil
            }
            return (session.id, activePanePID)
        }

        guard !pidPairs.isEmpty else {
            resourceMetricsBySessionID = [:]
            return
        }

        do {
            let metricsByPID = try await metricsClient.metrics(forRootPIDs: pidPairs.map(\.1))
            resourceMetricsBySessionID = Dictionary(uniqueKeysWithValues: pidPairs.compactMap { sessionID, pid in
                guard let metrics = metricsByPID[pid] else {
                    return nil
                }
                return (sessionID, metrics)
            })
            DiagnosticLog.write("metrics loaded count=\(resourceMetricsBySessionID.count)")
        } catch {
            resourceMetricsBySessionID = [:]
            DiagnosticLog.write("metrics failed error=\(readableMessage(error))")
        }
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
