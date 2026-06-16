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

    @Published private(set) var sessions: [TmuxSession] = []
    @Published private(set) var resourceMetricsBySessionID: [String: ProcessResourceMetrics] = [:]
    @Published private(set) var recentLinksBySessionID: [String: [DetectedLogLink]] = [:]
    @Published private(set) var panesBySessionID: [String: [TmuxPane]] = [:]
    @Published private(set) var selectedPaneBySessionID: [String: TmuxPane] = [:]
    @Published private(set) var selectedSession: TmuxSession?
    @Published private(set) var logBuffer = LogBuffer(pageSize: 200)
    @Published private(set) var logRevision = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingInitialLogs = false
    @Published private(set) var isRefreshingLogs = false
    @Published private(set) var isLoadingOlderLogs = false
    @Published private(set) var isMenuBarMenuPresented = false
    @Published var errorMessage: String?

    private let client: any TmuxClientProviding
    private let metricsClient: any ProcessMetricsProviding
    private var refreshLoopStarted = false
    private var logRefreshLoopStarted = false
    private var loadingInitialLogSessionIDs = Set<String>()
    private var logLinkScanCache = LogLinkScanCache()

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

    var selectedPane: TmuxPane? {
        guard let selectedSession else {
            return nil
        }
        return selectedPaneBySessionID[selectedSession.id]
    }

    func recentLinks(for session: TmuxSession) -> [DetectedLogLink] {
        recentLinksBySessionID[session.id] ?? []
    }

    func panes(for session: TmuxSession) -> [TmuxPane] {
        panesBySessionID[session.id] ?? []
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
            panesBySessionID = [:]
            selectedPaneBySessionID = [:]
            errorMessage = MacTMUXError.tmuxNotFound.localizedDescription
            DiagnosticLog.write("tmux path not found")
            return
        }

        guard TmuxPathResolver.isValidTmuxBinary(tmuxPath) else {
            sessions = []
            recentLinksBySessionID = [:]
            panesBySessionID = [:]
            selectedPaneBySessionID = [:]
            errorMessage = MacTMUXError.invalidTmuxPath(tmuxPath).localizedDescription
            DiagnosticLog.write("invalid tmux path \(tmuxPath)")
            return
        }

        do {
            let loadedSessions = try await loadSessions(tmuxPath: tmuxPath)
            sessions = loadedSessions
            await loadPanes(for: loadedSessions)
            await loadResourceMetricsIfNeeded(for: loadedSessions)
            await loadRecentLinks(for: loadedSessions)
            if let selectedSession {
                if let refreshedSelection = loadedSessions.first(where: { $0.id == selectedSession.id }) {
                    self.selectedSession = refreshedSelection
                    selectDefaultPaneIfNeeded(for: refreshedSelection)
                } else {
                    self.selectedSession = nil
                    clearLogs()
                }
            }
            if let selectedSession, let pane = selectedPane(for: selectedSession) {
                updateCurrentLogLinks(for: selectedSession, pane: pane)
            }
            errorMessage = nil
        } catch {
            sessions = []
            recentLinksBySessionID = [:]
            panesBySessionID = [:]
            selectedPaneBySessionID = [:]
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
        await loadPanesIfNeeded(for: session)
        selectDefaultPaneIfNeeded(for: session)
        await loadInitialLogs(for: session)
    }

    func selectPane(_ pane: TmuxPane, for session: TmuxSession) async {
        guard pane.sessionID == session.id else {
            return
        }
        if selectedPaneBySessionID[session.id]?.id != pane.id {
            selectedPaneBySessionID[session.id] = pane
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
            guard let pane = selectedPane(for: session) else {
                clearLogs()
                return
            }
            let output = try await client.captureLogs(pane: pane, startLine: -logBuffer.pageSize, endLine: -1)
            var nextBuffer = LogBuffer(pageSize: logBuffer.pageSize, maxRetainedLines: logBuffer.maxRetainedLines)
            _ = nextBuffer.reset(with: output)
            guard selectedSession?.id == session.id, selectedPane(for: session)?.id == pane.id else {
                return
            }
            logBuffer = nextBuffer
            logRevision += 1
            updateCurrentLogLinks(for: session, pane: pane, resetCache: true)
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
            guard let pane = selectedPane(for: session) else {
                return
            }
            let output = try await client.captureLogs(pane: pane, startLine: -logBuffer.pageSize, endLine: -1)
            var nextBuffer = logBuffer
            let result = nextBuffer.appendLatest(output)
            guard selectedSession?.id == session.id, selectedPane(for: session)?.id == pane.id else {
                return
            }
            if result.changed {
                logBuffer = nextBuffer
                logRevision += 1
                updateCurrentLogLinks(for: session, pane: pane, resetCache: result.replaced)
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
            guard let pane = selectedPane(for: session) else {
                return
            }
            let output = try await client.captureLogs(pane: pane, startLine: startLine, endLine: endLine)
            var nextBuffer = logBuffer
            let result = nextBuffer.prependOlder(output)
            guard selectedSession?.id == session.id, selectedPane(for: session)?.id == pane.id else {
                return
            }
            if result.changed {
                logBuffer = nextBuffer
                logRevision += 1
                updateCurrentLogLinks(for: session, pane: pane)
            } else {
                logBuffer = nextBuffer
            }
            errorMessage = nil
        } catch {
            errorMessage = readableMessage(error)
        }
    }

    func stop(_ session: TmuxSession) async {
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
            guard !isMenuBarMenuPresented else {
                continue
            }
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
            guard autoRefreshLogs, !isMenuBarMenuPresented, let selectedSession else {
                continue
            }
            await refreshLatestLogs(for: selectedSession)
        }
    }

    func setMenuBarMenuPresented(_ isPresented: Bool) {
        isMenuBarMenuPresented = isPresented
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
                let panes = panesBySessionID[session.id] ?? []
                group.addTask {
                    guard !panes.isEmpty else {
                        return (session.id, [])
                    }
                    do {
                        var output = ""
                        for pane in panes {
                            output += try await client.captureLogs(pane: pane, startLine: -pageSize, endLine: -1)
                            output += "\n"
                        }
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

    private func selectedPane(for session: TmuxSession) -> TmuxPane? {
        if let pane = selectedPaneBySessionID[session.id] {
            return pane
        }
        return panesBySessionID[session.id]?.first
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
        logLinkScanCache.reset()
        logRevision += 1
    }

    private func updateCurrentLogLinks(for session: TmuxSession, pane: TmuxPane, resetCache: Bool = false) {
        let contextID = "\(session.id)|\(pane.id)"
        if resetCache {
            logLinkScanCache.reset(contextID: contextID)
        }

        let links = logLinkScanCache.update(contextID: contextID, lines: logBuffer.lines)
        let mergedLinks = mergedRecentLinks(
            selectedPaneLinks: links,
            sessionLinks: recentLinksBySessionID[session.id] ?? []
        )
        if mergedLinks.isEmpty {
            recentLinksBySessionID.removeValue(forKey: session.id)
        } else {
            recentLinksBySessionID[session.id] = mergedLinks
        }
    }

    private func readableMessage(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description.isEmpty ? "Unknown error." : description
        }
        return error.localizedDescription
    }

    private func mergedRecentLinks(
        selectedPaneLinks: [DetectedLogLink],
        sessionLinks: [DetectedLogLink]
    ) -> [DetectedLogLink] {
        var merged: [DetectedLogLink] = []
        var seenURLStrings = Set<String>()

        for link in selectedPaneLinks + sessionLinks where seenURLStrings.insert(link.urlString).inserted {
            merged.append(link)
            if merged.count == LogLinkDetector.defaultMaxCount {
                break
            }
        }

        return merged
    }
}

private struct LogLinkScanCache {
    private struct CachedLink {
        var link: DetectedLogLink
        var sequence: Int
        var lineID: String
    }

    private var contextID: String?
    private var scannedLineIDs = Set<String>()
    private var baseURL: URL?
    private var linksByURLString: [String: CachedLink] = [:]

    mutating func reset(contextID: String? = nil) {
        self.contextID = contextID
        scannedLineIDs = []
        baseURL = nil
        linksByURLString = [:]
    }

    mutating func update(contextID: String, lines: [LogLine]) -> [DetectedLogLink] {
        if self.contextID != contextID {
            reset(contextID: contextID)
        }

        let retainedLineIDs = Set(lines.map(\.id))
        let needsRebuild = pruneRetainedState(retainedLineIDs: retainedLineIDs)
        var shouldRescanLinesWithBaseURL = false
        for line in lines where scannedLineIDs.insert(line.id).inserted {
            let links = LogLinkDetector.detectLinks(in: line.text, maxCount: 16, baseURL: baseURL)
            cache(links, sequence: line.sequence, lineID: line.id)
            if updateBaseURL(from: links) {
                shouldRescanLinesWithBaseURL = true
            }
        }

        if shouldRescanLinesWithBaseURL || needsRebuild, let baseURL {
            rebuildLinks(from: lines, baseURL: baseURL)
        } else if needsRebuild {
            rebuildLinks(from: lines, baseURL: nil)
        }

        return sortedLinks()
    }

    private mutating func rebuildLinks(from lines: [LogLine], baseURL: URL?) {
        linksByURLString = [:]
        for line in lines {
            let links = LogLinkDetector.detectLinks(in: line.text, maxCount: 16, baseURL: baseURL)
            cache(links, sequence: line.sequence, lineID: line.id)
        }
    }

    private mutating func pruneRetainedState(retainedLineIDs: Set<String>) -> Bool {
        let previousLinkCount = linksByURLString.count
        scannedLineIDs.formIntersection(retainedLineIDs)
        linksByURLString = linksByURLString.filter { retainedLineIDs.contains($0.value.lineID) }
        return linksByURLString.count != previousLinkCount
    }

    private func sortedLinks() -> [DetectedLogLink] {
        linksByURLString.values
            .sorted { left, right in
                if left.sequence == right.sequence {
                    return left.link.urlString < right.link.urlString
                }
                return left.sequence > right.sequence
            }
            .prefix(LogLinkDetector.defaultMaxCount)
            .map(\.link)
    }

    private mutating func cache(_ links: [DetectedLogLink], sequence: Int, lineID: String) {
        for link in links {
            let existing = linksByURLString[link.urlString]
            if existing == nil || sequence >= existing!.sequence {
                linksByURLString[link.urlString] = CachedLink(link: link, sequence: sequence, lineID: lineID)
            }
        }
    }

    private mutating func updateBaseURL(from links: [DetectedLogLink]) -> Bool {
        guard let inferredBaseURL = links.lazy.compactMap(Self.developmentBaseURL(from:)).first,
              inferredBaseURL != baseURL else {
            return false
        }

        baseURL = inferredBaseURL
        return true
    }

    private static func developmentBaseURL(from link: DetectedLogLink) -> URL? {
        guard var components = URLComponents(string: link.urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              isLocalDevelopmentHost(host) else {
            return nil
        }

        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isLocalDevelopmentHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1"
    }
}
