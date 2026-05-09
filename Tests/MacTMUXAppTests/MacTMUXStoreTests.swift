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

private actor EmptyMetricsClient: ProcessMetricsProviding {
    func metrics(forRootPIDs rootPIDs: [Int32]) async throws -> [Int32: ProcessResourceMetrics] {
        [:]
    }
}
