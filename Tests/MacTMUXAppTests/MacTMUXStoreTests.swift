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
        let client = ConfigurableTmuxClient(
            sessions: [firstSession, secondSession],
            logsBySessionID: [
                firstSession.id: "older https://older.example.com\nnewer https://newer.example.com\n",
                secondSession.id: "local localhost:5173/app\n"
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

    func testRefreshPrunesRecentLinksForRemovedSessions() async throws {
        let fixture = try TemporaryTmuxBinary()
        defer {
            fixture.remove()
        }

        let server = TmuxServer(binaryPath: fixture.tmuxPath)
        let firstSession = TmuxSession(server: server, name: "first", windows: 1, attached: false, createdAt: .now)
        let secondSession = TmuxSession(server: server, name: "second", windows: 1, attached: false, createdAt: .now)
        let client = ConfigurableTmuxClient(
            sessions: [firstSession, secondSession],
            logsBySessionID: [
                firstSession.id: "first https://first.example.com\n",
                secondSession.id: "second https://second.example.com\n"
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

    func captureLogs(session: TmuxSession, startLine: Int, endLine: Int) async throws -> String {
        if let delay = delaysBySessionID[session.id] {
            try? await Task.sleep(for: delay)
        }
        return logsBySessionID[session.id] ?? ""
    }

    func stop(session: TmuxSession) async throws {}

    func restartActivePane(session: TmuxSession) async throws {}
}

private actor ConfigurableTmuxClient: TmuxClientProviding {
    private var sessions: [TmuxSession]
    private var logsBySessionID: [String: String]
    private let delaysBySessionID: [String: Duration]

    init(sessions: [TmuxSession], logsBySessionID: [String: String], delaysBySessionID: [String: Duration] = [:]) {
        self.sessions = sessions
        self.logsBySessionID = logsBySessionID
        self.delaysBySessionID = delaysBySessionID
    }

    func setSessions(_ sessions: [TmuxSession]) {
        self.sessions = sessions
    }

    func listSessions(server: TmuxServer) async throws -> [TmuxSession] {
        sessions
    }

    func captureLogs(session: TmuxSession, startLine: Int, endLine: Int) async throws -> String {
        if let delay = delaysBySessionID[session.id] {
            try? await Task.sleep(for: delay)
        }
        return logsBySessionID[session.id] ?? ""
    }

    func stop(session: TmuxSession) async throws {}

    func restartActivePane(session: TmuxSession) async throws {}
}

private actor EmptyMetricsClient: ProcessMetricsProviding {
    func metrics(forRootPIDs rootPIDs: [Int32]) async throws -> [Int32: ProcessResourceMetrics] {
        [:]
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
