import MacTMUXCore
@testable import MacTMUXApp
import XCTest

@MainActor
final class MacTMUXStoreTests: XCTestCase {
    func testFastSessionSwitchKeepsLatestInitialLogs() async {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let firstSession = TmuxSession(server: server, name: "first", windows: 1, attached: false, createdAt: .now)
        let secondSession = TmuxSession(server: server, name: "second", windows: 1, attached: false, createdAt: .now)
        let client = DelayedLogClient(
            logsBySessionID: [
                firstSession.id: "first log\n",
                secondSession.id: "second log\n"
            ],
            delaysBySessionID: [
                firstSession.id: .milliseconds(120)
            ]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: EmptyMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )

        let firstSelection = Task { @MainActor in
            await store.select(firstSession)
        }
        try? await Task.sleep(for: .milliseconds(20))
        await store.select(secondSession)
        await firstSelection.value

        XCTAssertEqual(store.selectedSession?.id, secondSession.id)
        XCTAssertEqual(store.logLines.map(\.text), ["second log"])
        XCTAssertFalse(store.isLoadingInitialLogs)
    }

    func testRefreshPopulatesRecentLinksForSessions() async throws {
        let fixture = try TemporaryTmuxBinary()
        defer {
            fixture.remove()
        }

        let server = TmuxServer(binaryPath: fixture.tmuxPath)
        let firstSession = TmuxSession(server: server, name: "first", windows: 1, attached: false, createdAt: .now)
        let secondSession = TmuxSession(server: server, name: "second", windows: 1, attached: false, createdAt: .now)
        let firstPane = makePane(session: firstSession, paneID: "%1", windowIndex: 0, windowName: "dev")
        let secondPane = makePane(session: secondSession, paneID: "%2", windowIndex: 0, windowName: "app")
        let client = ConfigurableTmuxClient(
            sessions: [firstSession, secondSession],
            panesBySessionID: [
                firstSession.id: [firstPane],
                secondSession.id: [secondPane]
            ],
            logsByPaneID: [
                firstPane.id: "older https://older.example.com\nnewer https://newer.example.com\n",
                secondPane.id: "local localhost:5173/app\n"
            ],
            delaysBySessionID: [
                firstSession.id: .milliseconds(80)
            ]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: EmptyMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )
        store.tmuxPathSetting = fixture.tmuxPath
        defer {
            store.resetTmuxPathToAutodetect()
        }

        await store.refresh()

        XCTAssertEqual(store.recentLinks(for: firstSession).map(\.urlString), [
            "https://newer.example.com",
            "https://older.example.com"
        ])
        XCTAssertEqual(store.recentLinks(for: secondSession).map(\.urlString), [
            "http://localhost:5173/app"
        ])
    }

    func testSelectSessionLoadsFirstPaneLogsByDefault() async {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "app", windows: 2, attached: false, createdAt: .now)
        let firstPane = makePane(session: session, paneID: "%1", windowIndex: 0, windowName: "dev")
        let secondPane = makePane(session: session, paneID: "%2", windowIndex: 1, windowName: "queue")
        let client = ConfigurableTmuxClient(
            sessions: [session],
            panesBySessionID: [session.id: [firstPane, secondPane]],
            logsByPaneID: [
                firstPane.id: "dev log\n",
                secondPane.id: "queue log\n"
            ]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: EmptyMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )

        await store.select(session)

        XCTAssertEqual(store.selectedPane?.id, firstPane.id)
        XCTAssertEqual(store.logLines.map(\.text), ["dev log"])
    }

    func testSelectSessionCachesLinksFromLoadedLogs() async {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "app", windows: 1, attached: false, createdAt: .now)
        let pane = makePane(session: session, paneID: "%1", windowIndex: 0, windowName: "dev")
        let client = ConfigurableTmuxClient(
            sessions: [session],
            panesBySessionID: [session.id: [pane]],
            logsByPaneID: [
                pane.id: "ready on localhost:5173/app\napi https://example.com/newer\n"
            ]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: EmptyMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )

        await store.select(session)

        XCTAssertEqual(store.recentLinks(for: session).map(\.urlString), [
            "https://example.com/newer",
            "http://localhost:5173/app"
        ])
    }

    func testSelectSessionCachesRelativeRequestLinksAfterBaseURLAppears() async {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "app", windows: 1, attached: false, createdAt: .now)
        let pane = makePane(session: session, paneID: "%1", windowIndex: 0, windowName: "dev")
        let client = ConfigurableTmuxClient(
            sessions: [session],
            panesBySessionID: [session.id: [pane]],
            logsByPaneID: [
                pane.id: """
                15:48:03 Request » GET 200 /collections/news
                ready on http://localhost:9292
                15:48:04 Request » GET 404 /products/le-faitout
                """
            ]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: EmptyMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )

        await store.select(session)

        XCTAssertEqual(store.recentLinks(for: session).map(\.urlString), [
            "http://localhost:9292/products/le-faitout",
            "http://localhost:9292",
            "http://localhost:9292/collections/news"
        ])
    }

    func testSelectPaneReloadsLogsForThatPane() async {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "app", windows: 2, attached: false, createdAt: .now)
        let firstPane = makePane(session: session, paneID: "%1", windowIndex: 0, windowName: "dev")
        let secondPane = makePane(session: session, paneID: "%2", windowIndex: 1, windowName: "queue")
        let client = ConfigurableTmuxClient(
            sessions: [session],
            panesBySessionID: [session.id: [firstPane, secondPane]],
            logsByPaneID: [
                firstPane.id: "dev log\n",
                secondPane.id: "queue log\n"
            ]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: EmptyMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )

        await store.select(session)
        await store.selectPane(secondPane, for: session)

        XCTAssertEqual(store.selectedPane?.id, secondPane.id)
        XCTAssertEqual(store.logLines.map(\.text), ["queue log"])
    }

    func testRefreshAggregatesRecentLinksAcrossPanes() async throws {
        let fixture = try TemporaryTmuxBinary()
        defer {
            fixture.remove()
        }

        let server = TmuxServer(binaryPath: fixture.tmuxPath)
        let session = TmuxSession(server: server, name: "app", windows: 2, attached: false, createdAt: .now)
        let devPane = makePane(session: session, paneID: "%1", windowIndex: 0, windowName: "dev")
        let workerPane = makePane(session: session, paneID: "%2", windowIndex: 1, windowName: "queue")
        let client = ConfigurableTmuxClient(
            sessions: [session],
            panesBySessionID: [session.id: [devPane, workerPane]],
            logsByPaneID: [
                devPane.id: "Server address: http://localhost:53660\n",
                workerPane.id: "[ info ] Starting worker for queues: default\n"
            ]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: EmptyMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )
        store.tmuxPathSetting = fixture.tmuxPath
        defer {
            store.resetTmuxPathToAutodetect()
        }

        await store.refresh()

        XCTAssertEqual(store.recentLinks(for: session).map(\.urlString), ["http://localhost:53660"])
    }

    func testSelectingPaneWithoutLinksPreservesSessionLinksFromOtherPanes() async throws {
        let fixture = try TemporaryTmuxBinary()
        defer {
            fixture.remove()
        }

        let server = TmuxServer(binaryPath: fixture.tmuxPath)
        let session = TmuxSession(server: server, name: "app", windows: 2, attached: false, createdAt: .now)
        let devPane = makePane(session: session, paneID: "%1", windowIndex: 0, windowName: "dev")
        let workerPane = makePane(session: session, paneID: "%2", windowIndex: 1, windowName: "queue")
        let client = ConfigurableTmuxClient(
            sessions: [session],
            panesBySessionID: [session.id: [devPane, workerPane]],
            logsByPaneID: [
                devPane.id: "Server address: http://localhost:53660\n",
                workerPane.id: "[ info ] Starting worker for queues: default\n"
            ]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: EmptyMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )
        store.tmuxPathSetting = fixture.tmuxPath
        defer {
            store.resetTmuxPathToAutodetect()
        }

        await store.refresh()
        await store.select(session)
        await store.selectPane(workerPane, for: session)

        XCTAssertEqual(store.recentLinks(for: session).map(\.urlString), ["http://localhost:53660"])
    }

    func testRefreshPrunesRecentLinksForRemovedSessions() async throws {
        let fixture = try TemporaryTmuxBinary()
        defer {
            fixture.remove()
        }

        let server = TmuxServer(binaryPath: fixture.tmuxPath)
        let firstSession = TmuxSession(server: server, name: "first", windows: 1, attached: false, createdAt: .now)
        let secondSession = TmuxSession(server: server, name: "second", windows: 1, attached: false, createdAt: .now)
        let firstPane = makePane(session: firstSession, paneID: "%1", windowIndex: 0, windowName: "first")
        let secondPane = makePane(session: secondSession, paneID: "%2", windowIndex: 0, windowName: "second")
        let client = ConfigurableTmuxClient(
            sessions: [firstSession, secondSession],
            panesBySessionID: [
                firstSession.id: [firstPane],
                secondSession.id: [secondPane]
            ],
            logsByPaneID: [
                firstPane.id: "first https://first.example.com\n",
                secondPane.id: "second https://second.example.com\n"
            ]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: EmptyMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )
        store.tmuxPathSetting = fixture.tmuxPath
        defer {
            store.resetTmuxPathToAutodetect()
        }

        await store.refresh()
        await client.setSessions([secondSession])
        await store.refresh()

        XCTAssertTrue(store.recentLinks(for: firstSession).isEmpty)
        XCTAssertEqual(store.recentLinks(for: secondSession).map(\.urlString), [
            "https://second.example.com"
        ])
    }

    func testMetricsFailureDoesNotSetGlobalError() async throws {
        let fixture = try TemporaryTmuxBinary()
        defer {
            fixture.remove()
        }

        let server = TmuxServer(binaryPath: fixture.tmuxPath)
        let session = TmuxSession(
            server: server,
            name: "app",
            windows: 1,
            attached: false,
            createdAt: .now,
            activePanePID: 123
        )
        let pane = makePane(session: session, paneID: "%1", windowIndex: 0, windowName: "dev")
        let client = ConfigurableTmuxClient(
            sessions: [session],
            panesBySessionID: [session.id: [pane]],
            logsByPaneID: [pane.id: "ready\n"]
        )
        let store = MacTMUXStore(
            client: client,
            metricsClient: FailingMetricsClient(),
            refreshOnInit: false,
            startBackgroundTasks: false
        )
        store.tmuxPathSetting = fixture.tmuxPath
        defer {
            store.resetTmuxPathToAutodetect()
        }

        await store.refresh()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.metricsErrorMessage, "metrics unavailable")
    }
}

private actor DelayedLogClient: TmuxClientProviding {
    private let logsBySessionID: [String: String]
    private let delaysBySessionID: [String: Duration]

    init(logsBySessionID: [String: String], delaysBySessionID: [String: Duration]) {
        self.logsBySessionID = logsBySessionID
        self.delaysBySessionID = delaysBySessionID
    }

    func listSessions(server: TmuxServer) async throws -> [TmuxSession] {
        []
    }

    func listPanes(session: TmuxSession) async throws -> [TmuxPane] {
        [makePane(session: session, paneID: "%\(abs(session.id.hashValue))", windowIndex: 0, windowName: session.name)]
    }

    func captureLogs(session: TmuxSession, startLine: Int, endLine: Int) async throws -> String {
        if let delay = delaysBySessionID[session.id] {
            try? await Task.sleep(for: delay)
        }
        return logsBySessionID[session.id] ?? ""
    }

    func captureLogs(pane: TmuxPane, startLine: Int, endLine: Int) async throws -> String {
        if let delay = delaysBySessionID[pane.sessionID] {
            try? await Task.sleep(for: delay)
        }
        return logsBySessionID[pane.sessionID] ?? ""
    }

    func stop(session: TmuxSession) async throws {}

    func restartActivePane(session: TmuxSession) async throws {}
}

private actor ConfigurableTmuxClient: TmuxClientProviding {
    private var sessions: [TmuxSession]
    private var panesBySessionID: [String: [TmuxPane]]
    private var logsByPaneID: [String: String]
    private let delaysBySessionID: [String: Duration]

    init(
        sessions: [TmuxSession],
        panesBySessionID: [String: [TmuxPane]] = [:],
        logsByPaneID: [String: String],
        delaysBySessionID: [String: Duration] = [:]
    ) {
        self.sessions = sessions
        self.panesBySessionID = panesBySessionID
        self.logsByPaneID = logsByPaneID
        self.delaysBySessionID = delaysBySessionID
    }

    func setSessions(_ sessions: [TmuxSession]) {
        self.sessions = sessions
    }

    func listSessions(server: TmuxServer) async throws -> [TmuxSession] {
        sessions
    }

    func listPanes(session: TmuxSession) async throws -> [TmuxPane] {
        if let panes = panesBySessionID[session.id] {
            return panes
        }
        return [makePane(session: session, paneID: "%\(abs(session.id.hashValue))", windowIndex: 0, windowName: session.name)]
    }

    func captureLogs(session: TmuxSession, startLine: Int, endLine: Int) async throws -> String {
        if let delay = delaysBySessionID[session.id] {
            try? await Task.sleep(for: delay)
        }
        let pane = try await listPanes(session: session).first
        return pane.flatMap { logsByPaneID[$0.id] } ?? ""
    }

    func captureLogs(pane: TmuxPane, startLine: Int, endLine: Int) async throws -> String {
        if let delay = delaysBySessionID[pane.sessionID] {
            try? await Task.sleep(for: delay)
        }
        return logsByPaneID[pane.id] ?? ""
    }

    func stop(session: TmuxSession) async throws {}

    func restartActivePane(session: TmuxSession) async throws {}
}

private func makePane(
    session: TmuxSession,
    paneID: String,
    windowIndex: Int,
    windowName: String,
    paneIndex: Int = 0,
    currentCommand: String = "node"
) -> TmuxPane {
    TmuxPane(
        server: session.server,
        sessionName: session.name,
        sessionID: session.id,
        paneID: paneID,
        windowIndex: windowIndex,
        windowName: windowName,
        windowActive: windowIndex == 0,
        paneIndex: paneIndex,
        paneActive: paneIndex == 0,
        panePID: nil,
        currentCommand: currentCommand
    )
}

private actor EmptyMetricsClient: ProcessMetricsProviding {
    func metrics(forRootPIDs rootPIDs: [Int32]) async throws -> [Int32: ProcessResourceMetrics] {
        [:]
    }
}

private actor FailingMetricsClient: ProcessMetricsProviding {
    func metrics(forRootPIDs rootPIDs: [Int32]) async throws -> [Int32: ProcessResourceMetrics] {
        throw MacTMUXError.commandFailed("metrics unavailable")
    }
}

private struct TemporaryTmuxBinary {
    let directoryURL: URL
    let tmuxPath: String

    init() throws {
        directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mactmux-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let tmuxURL = directoryURL.appendingPathComponent("tmux")
        try "#!/bin/sh\n".write(to: tmuxURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmuxURL.path)
        tmuxPath = tmuxURL.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
