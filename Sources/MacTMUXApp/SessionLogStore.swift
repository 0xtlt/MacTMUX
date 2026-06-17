import MacTMUXCore
import Foundation

@MainActor
final class SessionLogStore {
    private let client: any TmuxClientProviding
    private var loadingInitialLogSessionIDs = Set<String>()
    private var logLinkScanCache = LogLinkScanCache()
    private var notifyChange: () -> Void

    private(set) var recentLinksBySessionID: [String: [DetectedLogLink]] = [:]
    private(set) var logBuffer = LogBuffer(pageSize: 200)
    private(set) var logRevision = 0
    private(set) var isLoadingInitialLogs = false
    private(set) var isRefreshingLogs = false
    private(set) var isLoadingOlderLogs = false

    init(client: any TmuxClientProviding, notifyChange: @escaping () -> Void = {}) {
        self.client = client
        self.notifyChange = notifyChange
    }

    func setNotifyChange(_ notifyChange: @escaping () -> Void) {
        self.notifyChange = notifyChange
    }

    var logLines: [LogLine] {
        logBuffer.lines
    }

    var isLoadingLogs: Bool {
        isLoadingInitialLogs || isRefreshingLogs || isLoadingOlderLogs
    }

    func canLoadOlderLogs(selectedSession: TmuxSession?) -> Bool {
        logBuffer.hasMoreOlderLogs &&
            !isLoadingInitialLogs(for: selectedSession) &&
            !isRefreshingLogs &&
            !isLoadingOlderLogs
    }

    func isLoadingInitialLogs(for session: TmuxSession?) -> Bool {
        guard let session else {
            return false
        }
        return loadingInitialLogSessionIDs.contains(session.id)
    }

    func recentLinks(for session: TmuxSession) -> [DetectedLogLink] {
        recentLinksBySessionID[session.id] ?? []
    }

    func clearAllSessionState() {
        recentLinksBySessionID = [:]
        clearLogs()
    }

    func clearLogs() {
        var nextBuffer = logBuffer
        nextBuffer.clear()
        logBuffer = nextBuffer
        logLinkScanCache.reset()
        logRevision += 1
        notifyChange()
    }

    func loadInitialLogs(
        for session: TmuxSession,
        pane: TmuxPane?,
        isCurrentSelection: @MainActor (TmuxSession, TmuxPane) -> Bool
    ) async throws {
        guard !isLoadingInitialLogs(for: session) else {
            return
        }
        setInitialLogLoading(true, for: session.id)
        defer {
            setInitialLogLoading(false, for: session.id)
        }

        guard let pane else {
            clearLogs()
            return
        }

        let output = try await client.captureLogs(pane: pane, startLine: -logBuffer.pageSize, endLine: -1)
        var nextBuffer = LogBuffer(pageSize: logBuffer.pageSize, maxRetainedLines: logBuffer.maxRetainedLines)
        _ = nextBuffer.reset(with: output)
        guard isCurrentSelection(session, pane) else {
            return
        }
        logBuffer = nextBuffer
        logRevision += 1
        updateCurrentLogLinks(for: session, pane: pane, resetCache: true)
        notifyChange()
    }

    func refreshLatestLogs(
        for session: TmuxSession,
        pane: TmuxPane?,
        isCurrentSelection: @MainActor (TmuxSession, TmuxPane) -> Bool
    ) async throws {
        guard !isLoadingInitialLogs(for: session), !isRefreshingLogs else {
            return
        }
        isRefreshingLogs = true
        notifyChange()
        defer {
            isRefreshingLogs = false
            notifyChange()
        }

        guard let pane else {
            return
        }

        let output = try await client.captureLogs(pane: pane, startLine: -logBuffer.pageSize, endLine: -1)
        var nextBuffer = logBuffer
        let result = nextBuffer.appendLatest(output)
        guard isCurrentSelection(session, pane) else {
            return
        }
        if result.changed {
            logBuffer = nextBuffer
            logRevision += 1
            updateCurrentLogLinks(for: session, pane: pane, resetCache: result.replaced)
            notifyChange()
        }
    }

    func loadOlderLogs(
        for session: TmuxSession,
        pane: TmuxPane?,
        isCurrentSelection: @MainActor (TmuxSession, TmuxPane) -> Bool
    ) async throws {
        guard canLoadOlderLogs(selectedSession: session) else {
            return
        }
        isLoadingOlderLogs = true
        notifyChange()
        defer {
            isLoadingOlderLogs = false
            notifyChange()
        }

        let pageSize = logBuffer.pageSize
        let loadedLines = max(logBuffer.loadedBacklogLines, pageSize)
        let startLine = -(loadedLines + pageSize)
        let endLine = -(loadedLines + 1)

        guard let pane else {
            return
        }

        let output = try await client.captureLogs(pane: pane, startLine: startLine, endLine: endLine)
        var nextBuffer = logBuffer
        let result = nextBuffer.prependOlder(output)
        guard isCurrentSelection(session, pane) else {
            return
        }
        if result.changed {
            logBuffer = nextBuffer
            logRevision += 1
            updateCurrentLogLinks(for: session, pane: pane)
        } else {
            logBuffer = nextBuffer
        }
        notifyChange()
    }

    func loadRecentLinks(for sessions: [TmuxSession], panesBySessionID: [String: [TmuxPane]]) async {
        let validSessionIDs = Set(sessions.map(\.id))
        var nextLinksBySessionID = recentLinksBySessionID.filter { validSessionIDs.contains($0.key) }
        guard !sessions.isEmpty else {
            recentLinksBySessionID = [:]
            notifyChange()
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
        notifyChange()
    }

    func updateCurrentLogLinks(for session: TmuxSession, pane: TmuxPane, resetCache: Bool = false) {
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
        notifyChange()
    }

    private func setInitialLogLoading(_ loading: Bool, for sessionID: String) {
        if loading {
            loadingInitialLogSessionIDs.insert(sessionID)
        } else {
            loadingInitialLogSessionIDs.remove(sessionID)
        }
        isLoadingInitialLogs = !loadingInitialLogSessionIDs.isEmpty
        notifyChange()
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
