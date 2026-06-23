import MacTMUXCore
import SwiftUI

protocol TmuxClientProviding: Sendable {
    func listSessions(server: TmuxServer) async throws -> [TmuxSession]
    func listPanes(session: TmuxSession) async throws -> [TmuxPane]
    func captureLogs(session: TmuxSession, startLine: Int, endLine: Int) async throws -> String
    func captureLogs(pane: TmuxPane, startLine: Int, endLine: Int) async throws -> String
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

    @Published private(set) var isRefreshing = false
    @Published private(set) var activeError: MacTMUXStoreError?

    private let client: any TmuxClientProviding
    private let sessionStore: SessionStore
    private let logStore: SessionLogStore
    private let resourceMetricsStore: ResourceMetricsStore
    private let presentationStore: AppPresentationStore
    private let minimumRefreshInterval: Double
    private let logRefreshInterval: Double
    private var refreshLoopStarted = false
    private var logRefreshLoopStarted = false

    init(
        client: any TmuxClientProviding = TmuxClient(),
        metricsClient: any ProcessMetricsProviding = ProcessMetricsClient(),
        presentationStore: AppPresentationStore = AppPresentationStore(),
        refreshOnInit: Bool = true,
        startBackgroundTasks: Bool = true,
        minimumRefreshInterval: Double = 2.0,
        logRefreshInterval: Double = 1.0
    ) {
        self.client = client
        self.sessionStore = SessionStore(client: client)
        self.logStore = SessionLogStore(client: client)
        self.resourceMetricsStore = ResourceMetricsStore(metricsClient: metricsClient)
        self.presentationStore = presentationStore
        self.minimumRefreshInterval = minimumRefreshInterval
        self.logRefreshInterval = logRefreshInterval
        self.sessionStore.setNotifyChange { [weak self] in
            self?.objectWillChange.send()
        }
        self.logStore.setNotifyChange { [weak self] in
            self?.objectWillChange.send()
        }
        self.resourceMetricsStore.setNotifyChange { [weak self] in
            self?.objectWillChange.send()
        }
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

    var sessions: [TmuxSession] {
        sessionStore.sessions
    }

    var compactSessions: [TmuxSession] {
        sessionStore.compactSessions
    }

    var panesBySessionID: [String: [TmuxPane]] {
        sessionStore.panesBySessionID
    }

    var selectedPaneBySessionID: [String: TmuxPane] {
        sessionStore.selectedPaneBySessionID
    }

    var selectedSession: TmuxSession? {
        sessionStore.selectedSession
    }

    var resourceMetricsBySessionID: [String: ProcessResourceMetrics] {
        resourceMetricsStore.metricsBySessionID
    }

    var metricsErrorMessage: String? {
        resourceMetricsStore.errorMessage
    }

    var logLines: [LogLine] {
        logStore.logLines
    }

    var logBuffer: LogBuffer {
        logStore.logBuffer
    }

    var logRevision: Int {
        logStore.logRevision
    }

    var isLoadingInitialLogs: Bool {
        logStore.isLoadingInitialLogs
    }

    var isRefreshingLogs: Bool {
        logStore.isRefreshingLogs
    }

    var isLoadingOlderLogs: Bool {
        logStore.isLoadingOlderLogs
    }

    var errorMessage: String? {
        activeError?.message
    }

    var isMenuBarMenuPresented: Bool {
        presentationStore.isMenuBarMenuPresented
    }

    var selectedPane: TmuxPane? {
        sessionStore.selectedPane
    }

    func recentLinks(for session: TmuxSession) -> [DetectedLogLink] {
        logStore.recentLinks(for: session)
    }

    func panes(for session: TmuxSession) -> [TmuxPane] {
        sessionStore.panes(for: session)
    }

    var canLoadOlderLogs: Bool {
        logStore.canLoadOlderLogs(selectedSession: selectedSession)
    }

    var isLoadingLogs: Bool {
        logStore.isLoadingLogs
    }

    var isLoadingSelectedInitialLogs: Bool {
        logStore.isLoadingInitialLogs(for: selectedSession)
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
                resourceMetricsStore.clear()
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
            sessionStore.clearAll()
            logStore.clearAllSessionState()
            setError(.tmux, MacTMUXError.tmuxNotFound)
            DiagnosticLog.write("tmux path not found")
            return
        }

        guard TmuxPathResolver.isValidTmuxBinary(tmuxPath) else {
            sessionStore.clearAll()
            logStore.clearAllSessionState()
            setError(.tmux, MacTMUXError.invalidTmuxPath(tmuxPath))
            DiagnosticLog.write("invalid tmux path \(tmuxPath)")
            return
        }

        do {
            let result = try await sessionStore.refresh(tmuxPath: tmuxPath)
            await loadResourceMetricsIfNeeded(for: result.sessions)
            await loadRecentLinks(for: result.sessions)
            if result.removedSelectedSession {
                logStore.clearLogs()
            }
            if let selectedSession, let pane = selectedPane(for: selectedSession) {
                logStore.updateCurrentLogLinks(for: selectedSession, pane: pane)
            }
            clearError(.tmux)
        } catch {
            sessionStore.clearAll()
            logStore.clearAllSessionState()
            setError(.tmux, error)
        }
    }

    func open(_ session: TmuxSession) async {
        do {
            try await TerminalLauncher(kind: terminalKind).open(session: session)
            clearError(.terminal)
        } catch {
            setError(.terminal, error)
        }
    }

    func select(_ session: TmuxSession) async {
        let changedSelection = await sessionStore.select(session)
        if changedSelection {
            logStore.clearLogs()
        }
        await loadInitialLogs(for: session)
    }

    func selectPane(_ pane: TmuxPane, for session: TmuxSession) async {
        guard pane.sessionID == session.id else {
            return
        }
        let changedPane = sessionStore.selectPane(pane, for: session)
        if changedPane {
            logStore.clearLogs()
        }
        await loadInitialLogs(for: session)
    }

    func loadLogs(for session: TmuxSession) async {
        await refreshLatestLogs(for: session)
    }

    func loadInitialLogs(for session: TmuxSession) async {
        do {
            try await logStore.loadInitialLogs(
                for: session,
                pane: selectedPane(for: session),
                isCurrentSelection: isCurrentSelection
            )
            clearError(.logs)
        } catch {
            guard selectedSession?.id == session.id else {
                return
            }
            logStore.clearLogs()
            setError(.logs, error)
        }
    }

    func refreshLatestLogs(for session: TmuxSession) async {
        guard selectedSession?.id == session.id else {
            return
        }

        do {
            try await logStore.refreshLatestLogs(
                for: session,
                pane: selectedPane(for: session),
                isCurrentSelection: isCurrentSelection
            )
            clearError(.logs)
        } catch {
            setError(.logs, error)
        }
    }

    func loadOlderLogs(for session: TmuxSession) async {
        guard canLoadOlderLogs, selectedSession?.id == session.id else {
            return
        }

        do {
            try await logStore.loadOlderLogs(
                for: session,
                pane: selectedPane(for: session),
                isCurrentSelection: isCurrentSelection
            )
            clearError(.logs)
        } catch {
            setError(.logs, error)
        }
    }

    func stop(_ session: TmuxSession) async {
        do {
            try await client.stop(session: session)
            await refresh()
        } catch {
            setError(.sessionAction, error)
        }
    }

    @discardableResult
    func stopSessions(_ sessions: [TmuxSession]) async -> Set<String> {
        let sessionsToStop = uniqueSessions(sessions)
        guard !sessionsToStop.isEmpty else {
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
            clearError(.sessionAction)
        } else {
            setError(.sessionAction, bulkStopFailureMessage(failures))
        }
        return stoppedIDs
    }

    func restart(_ session: TmuxSession) async {
        do {
            try await client.restartActivePane(session: session)
            logStore.clearLogs()
            await loadInitialLogs(for: session)
            clearError(.sessionAction)
        } catch {
            setError(.sessionAction, error)
        }
    }

    func resetTmuxPathToAutodetect() {
        configuredTmuxPath = ""
    }

    func clearSelection() {
        sessionStore.clearSelection()
        logStore.clearLogs()
    }

    func metricsText(for session: TmuxSession) -> String? {
        resourceMetricsStore.metricsText(for: session, isEnabled: showResourceMetrics)
    }

    func startRefreshLoop() async {
        guard !refreshLoopStarted else {
            DiagnosticLog.write("refresh loop already started")
            return
        }
        refreshLoopStarted = true
        DiagnosticLog.write("refresh loop started interval=\(refreshInterval)")

        while !Task.isCancelled {
            let seconds = max(minimumRefreshInterval, refreshInterval)
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
            let seconds = max(0.5, logRefreshInterval)
            try? await Task.sleep(for: .seconds(seconds))
            guard autoRefreshLogs, let selectedSession else {
                continue
            }
            await refreshLatestLogs(for: selectedSession)
        }
    }

    func setMenuBarMenuPresented(_ isPresented: Bool) {
        presentationStore.setMenuBarMenuPresented(isPresented)
    }

    private func loadResourceMetricsIfNeeded(for sessions: [TmuxSession]) async {
        await resourceMetricsStore.loadIfEnabled(for: sessions, isEnabled: showResourceMetrics)
    }

    private func loadRecentLinks(for sessions: [TmuxSession]) async {
        await logStore.loadRecentLinks(for: sessions, panesBySessionID: panesBySessionID)
    }

    private func selectedPane(for session: TmuxSession) -> TmuxPane? {
        sessionStore.selectedPane(for: session)
    }

    private func uniqueSessions(_ sessions: [TmuxSession]) -> [TmuxSession] {
        var seenIDs = Set<String>()
        return sessions.filter { session in
            seenIDs.insert(session.id).inserted
        }
    }

    private func bulkStopFailureMessage(_ failures: [String]) -> String {
        let shownFailures = failures.prefix(3).joined(separator: "\n")
        let remainingCount = failures.count - 3
        let remainingText = remainingCount > 0 ? "\nand \(remainingCount) more." : ""
        return "Failed to stop \(failures.count) session\(failures.count == 1 ? "" : "s"):\n\(shownFailures)\(remainingText)"
    }

    private func isCurrentSelection(session: TmuxSession, pane: TmuxPane) -> Bool {
        selectedSession?.id == session.id && selectedPane(for: session)?.id == pane.id
    }

    private func readableMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description.isEmpty ? "Unknown error." : description
        }
        return error.localizedDescription
    }

    private func setError(_ scope: MacTMUXStoreErrorScope, _ error: Error) {
        setError(scope, readableMessage(error))
    }

    private func setError(_ scope: MacTMUXStoreErrorScope, _ message: String) {
        activeError = MacTMUXStoreError(scope: scope, message: message)
    }

    private func clearError(_ scope: MacTMUXStoreErrorScope) {
        if activeError?.scope == scope {
            activeError = nil
        }
    }

}
