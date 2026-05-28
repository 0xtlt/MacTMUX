import AppKit
import MacTMUXCore
import SwiftUI

protocol TmuxClientProviding: Sendable {
    func listSessions(server: TmuxServer) async throws -> [TmuxSession]
    func captureLogs(session: TmuxSession, startLine: Int, endLine: Int) async throws -> String
    func stop(session: TmuxSession) async throws
    func restartActivePane(session: TmuxSession) async throws
}

extension TmuxClient: TmuxClientProviding {}

protocol ProcessMetricsProviding: Sendable {
    func metrics(forRootPIDs rootPIDs: [Int32]) async throws -> [Int32: ProcessResourceMetrics]
}

extension ProcessMetricsClient: ProcessMetricsProviding {}

@MainActor
final class MacTMUXStore: ObservableObject {
    @AppStorage("tmuxBinaryPath") private var configuredTmuxPath = ""
    @AppStorage("terminalKind") private var terminalKindRaw = TerminalKind.terminalApp.rawValue
    @AppStorage("refreshInterval") var refreshInterval = 5.0
    @AppStorage("showResourceMetrics") private var showResourceMetricsRaw = true
    @AppStorage("autoRefreshLogs") private var autoRefreshLogsRaw = true

    @Published private(set) var sessions: [TmuxSession] = []
    @Published private(set) var resourceMetricsBySessionID: [String: ProcessResourceMetrics] = [:]
    @Published private(set) var recentLinksBySessionID: [String: [DetectedLogLink]] = [:]
    @Published private(set) var selectedSession: TmuxSession?
    @Published private(set) var logBuffer = LogBuffer(pageSize: 200)
    @Published private(set) var logRevision = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingInitialLogs = false
    @Published private(set) var isRefreshingLogs = false
    @Published private(set) var isLoadingOlderLogs = false
    @Published var errorMessage: String?

    private let client: any TmuxClientProviding
    private let metricsClient: any ProcessMetricsProviding
    private var refreshLoopStarted = false
    private var logRefreshLoopStarted = false
    private var loadingInitialLogSessionIDs = Set<String>()

    init(
        client: any TmuxClientProviding = TmuxClient(),
        metricsClient: any ProcessMetricsProviding = ProcessMetricsClient(),
        refreshOnInit: Bool = true,
        startBackgroundTasks: Bool = true
    ) {
        self.client = client
        self.metricsClient = metricsClient
        DiagnosticLog.clear()
        DiagnosticLog.write("store init")
        if refreshOnInit {
            Task {
                await refresh()
            }
        }
        if startBackgroundTasks {
            Task {
                await startRefreshLoop()
            }
            Task {
                await startLogRefreshLoop()
            }
        }
    }

    var compactSessions: [TmuxSession] {
        Array(sessions.prefix(5))
    }

    var logLines: [LogLine] {
        logBuffer.lines
    }

    func recentLinks(for session: TmuxSession) -> [DetectedLogLink] {
        recentLinksBySessionID[session.id] ?? []
    }

    var canLoadOlderLogs: Bool {
        logBuffer.hasMoreOlderLogs && !isLoadingSelectedInitialLogs && !isRefreshingLogs && !isLoadingOlderLogs
    }

    var isLoadingLogs: Bool {
        isLoadingSelectedInitialLogs || isRefreshingLogs || isLoadingOlderLogs
    }

    var isLoadingSelectedInitialLogs: Bool {
        guard let selectedSession else {
            return false
        }
        return loadingInitialLogSessionIDs.contains(selectedSession.id)
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

    var autoRefreshLogs: Bool {
        get {
            autoRefreshLogsRaw
        }
        set {
            autoRefreshLogsRaw = newValue
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
            recentLinksBySessionID = [:]
            errorMessage = MacTMUXError.tmuxNotFound.localizedDescription
            DiagnosticLog.write("tmux path not found")
            return
        }

        guard TmuxPathResolver.isValidTmuxBinary(tmuxPath) else {
            sessions = []
            recentLinksBySessionID = [:]
            errorMessage = MacTMUXError.invalidTmuxPath(tmuxPath).localizedDescription
            DiagnosticLog.write("invalid tmux path \(tmuxPath)")
            return
        }

        do {
            let loadedSessions = try await loadSessions(tmuxPath: tmuxPath)
            sessions = loadedSessions
            await loadResourceMetricsIfNeeded(for: loadedSessions)
            await loadRecentLinks(for: loadedSessions)
            if let selectedSession {
                if let refreshedSelection = loadedSessions.first(where: { $0.id == selectedSession.id }) {
                    self.selectedSession = refreshedSelection
                } else {
                    self.selectedSession = nil
                    clearLogs()
                }
            }
            errorMessage = nil
        } catch {
            sessions = []
            recentLinksBySessionID = [:]
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
        if selectedSession?.id != session.id {
            clearLogs()
        }
        selectedSession = session
        await loadInitialLogs(for: session)
    }

    func loadLogs(for session: TmuxSession) async {
        await refreshLatestLogs(for: session)
    }

    func loadInitialLogs(for session: TmuxSession) async {
        guard !isLoadingInitialLogs(for: session) else {
            return
        }
        setInitialLogLoading(true, for: session.id)
        defer {
            setInitialLogLoading(false, for: session.id)
        }

        do {
            let output = try await client.captureLogs(session: session, startLine: -logBuffer.pageSize, endLine: -1)
            var nextBuffer = LogBuffer(pageSize: logBuffer.pageSize, maxRetainedLines: logBuffer.maxRetainedLines)
            _ = nextBuffer.reset(with: output)
            guard selectedSession?.id == session.id else {
                return
            }
            logBuffer = nextBuffer
            logRevision += 1
            errorMessage = nil
        } catch {
            guard selectedSession?.id == session.id else {
                return
            }
            clearLogs()
            errorMessage = readableMessage(error)
        }
    }

    func refreshLatestLogs(for session: TmuxSession) async {
        guard !isLoadingInitialLogs(for: session), !isRefreshingLogs, selectedSession?.id == session.id else {
            return
        }
        isRefreshingLogs = true
        defer {
            isRefreshingLogs = false
        }

        do {
            let output = try await client.captureLogs(session: session, startLine: -logBuffer.pageSize, endLine: -1)
            var nextBuffer = logBuffer
            let result = nextBuffer.appendLatest(output)
            guard selectedSession?.id == session.id else {
                return
            }
            if result.changed {
                logBuffer = nextBuffer
                logRevision += 1
            }
            errorMessage = nil
        } catch {
            errorMessage = readableMessage(error)
        }
    }

    func loadOlderLogs(for session: TmuxSession) async {
        guard canLoadOlderLogs, selectedSession?.id == session.id else {
            return
        }
        isLoadingOlderLogs = true
        defer {
            isLoadingOlderLogs = false
        }

        let pageSize = logBuffer.pageSize
        let loadedLines = max(logBuffer.loadedBacklogLines, pageSize)
        let startLine = -(loadedLines + pageSize)
        let endLine = -(loadedLines + 1)

        do {
            let output = try await client.captureLogs(session: session, startLine: startLine, endLine: endLine)
            var nextBuffer = logBuffer
            let result = nextBuffer.prependOlder(output)
            guard selectedSession?.id == session.id else {
                return
            }
            if result.changed {
                logBuffer = nextBuffer
                logRevision += 1
            } else {
                logBuffer = nextBuffer
            }
            errorMessage = nil
        } catch {
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

    @discardableResult
    func stopSessions(_ sessions: [TmuxSession]) async -> Set<String> {
        let sessionsToStop = uniqueSessions(sessions)
        guard !sessionsToStop.isEmpty else {
            return []
        }

        let title = sessionsToStop.count == 1
            ? "Stop \(sessionsToStop[0].name)?"
            : "Stop \(sessionsToStop.count) sessions?"
        guard confirm(title: title, message: bulkStopMessage(for: sessionsToStop)) else {
            return []
        }

        var stoppedIDs = Set<String>()
        var failures: [String] = []
        for session in sessionsToStop {
            do {
                try await client.stop(session: session)
                stoppedIDs.insert(session.id)
            } catch {
                failures.append("\(session.name): \(readableMessage(error))")
            }
        }

        await refresh()
        if failures.isEmpty {
            errorMessage = nil
        } else {
            errorMessage = bulkStopFailureMessage(failures)
        }
        return stoppedIDs
    }

    func restart(_ session: TmuxSession) async {
        guard confirm(title: "Restart \(session.name)?", message: "This will respawn the active pane in the selected tmux session.") else {
            return
        }

        do {
            try await client.restartActivePane(session: session)
            await refreshLatestLogs(for: session)
            errorMessage = nil
        } catch {
            errorMessage = readableMessage(error)
        }
    }

    func resetTmuxPathToAutodetect() {
        configuredTmuxPath = ""
    }

    func clearSelection() {
        selectedSession = nil
        clearLogs()
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

    func startLogRefreshLoop() async {
        guard !logRefreshLoopStarted else {
            DiagnosticLog.write("log refresh loop already started")
            return
        }
        logRefreshLoopStarted = true
        DiagnosticLog.write("log refresh loop started")

        while !Task.isCancelled {
            let seconds = max(2.0, refreshInterval)
            try? await Task.sleep(for: .seconds(seconds))
            guard autoRefreshLogs, let selectedSession else {
                continue
            }
            await refreshLatestLogs(for: selectedSession)
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

    private func loadRecentLinks(for sessions: [TmuxSession]) async {
        let validSessionIDs = Set(sessions.map(\.id))
        var nextLinksBySessionID = recentLinksBySessionID.filter { validSessionIDs.contains($0.key) }
        guard !sessions.isEmpty else {
            recentLinksBySessionID = [:]
            return
        }

        let client = self.client
        let pageSize = min(80, logBuffer.pageSize)
        let capturedLinks = await withTaskGroup(of: (String, [DetectedLogLink]?).self) { group in
            for session in sessions {
                group.addTask {
                    do {
                        let output = try await client.captureLogs(session: session, startLine: -pageSize, endLine: -1)
                        return (session.id, LogLinkDetector.detectLinks(in: output))
                    } catch {
                        DiagnosticLog.write("link capture failed session=\(session.name) error=\(error.localizedDescription)")
                        return (session.id, nil)
                    }
                }
            }

            var linksBySessionID: [(String, [DetectedLogLink]?)] = []
            for await result in group {
                linksBySessionID.append(result)
            }
            return linksBySessionID
        }

        for (sessionID, links) in capturedLinks {
            guard let links else {
                continue
            }
            if links.isEmpty {
                nextLinksBySessionID.removeValue(forKey: sessionID)
            } else {
                nextLinksBySessionID[sessionID] = links
            }
        }

        recentLinksBySessionID = nextLinksBySessionID
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

    private func uniqueSessions(_ sessions: [TmuxSession]) -> [TmuxSession] {
        var seenIDs = Set<String>()
        return sessions.filter { session in
            seenIDs.insert(session.id).inserted
        }
    }

    private func bulkStopMessage(for sessions: [TmuxSession]) -> String {
        let prefix = sessions.count == 1
            ? "This will kill the selected tmux session."
            : "This will kill the selected tmux sessions."
        let shownNames = sessions.prefix(8).map { "- \($0.name)" }.joined(separator: "\n")
        let remainingCount = sessions.count - 8
        let remainingText = remainingCount > 0 ? "\nand \(remainingCount) more." : ""
        return "\(prefix)\n\n\(shownNames)\(remainingText)"
    }

    private func bulkStopFailureMessage(_ failures: [String]) -> String {
        let shownFailures = failures.prefix(3).joined(separator: "\n")
        let remainingCount = failures.count - 3
        let remainingText = remainingCount > 0 ? "\nand \(remainingCount) more." : ""
        return "Failed to stop \(failures.count) session\(failures.count == 1 ? "" : "s"):\n\(shownFailures)\(remainingText)"
    }

    private func isLoadingInitialLogs(for session: TmuxSession) -> Bool {
        loadingInitialLogSessionIDs.contains(session.id)
    }

    private func setInitialLogLoading(_ loading: Bool, for sessionID: String) {
        if loading {
            loadingInitialLogSessionIDs.insert(sessionID)
        } else {
            loadingInitialLogSessionIDs.remove(sessionID)
        }
        isLoadingInitialLogs = !loadingInitialLogSessionIDs.isEmpty
    }

    private func clearLogs() {
        var nextBuffer = logBuffer
        nextBuffer.clear()
        logBuffer = nextBuffer
        logRevision += 1
    }

    private func readableMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description.isEmpty ? "Unknown error." : description
        }
        return error.localizedDescription
    }
}
