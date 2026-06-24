import MacTMUXCore
@testable import MacTMUXApp
import XCTest

final class MenuBarSnapshotTests: XCTestCase {
    func testCompactSessionsCapsVisibleMenuSessions() {
        let sessions = makeSessions(named: ["one", "two", "three", "four", "five", "six"])
        let snapshot = MenuBarSnapshot(sessions: sessions)

        XCTAssertEqual(snapshot.compactSessions.map(\.name), ["one", "two", "three", "four", "five"])
        XCTAssertEqual(snapshot.hiddenSessionCount, 1)
    }

    func testSnapshotKeepsPerSessionLinksAndMetrics() {
        let sessions = makeSessions(named: ["app", "worker"])
        let link = DetectedLogLink(urlString: "https://example.com/preview")
        let snapshot = MenuBarSnapshot(
            sessions: sessions,
            recentLinksBySessionID: [sessions[0].id: [link]],
            metricsTextBySessionID: [sessions[0].id: "CPU 1.0% · RAM 20 MB"]
        )

        XCTAssertEqual(snapshot.recentLinks(for: sessions[0]), [link])
        XCTAssertTrue(snapshot.recentLinks(for: sessions[1]).isEmpty)
        XCTAssertEqual(snapshot.metricsText(for: sessions[0]), "CPU 1.0% · RAM 20 MB")
        XCTAssertNil(snapshot.metricsText(for: sessions[1]))
    }

    func testSessionSignatureTracksSessionSummaryOnly() {
        let sessions = makeSessions(named: ["app", "worker"])
        let sameSessionsWithDifferentLinks = MenuBarSnapshot(
            sessions: sessions,
            recentLinksBySessionID: [sessions[0].id: [DetectedLogLink(urlString: "https://example.com")]]
        )
        let removedSession = MenuBarSnapshot(sessions: [sessions[0]])

        XCTAssertEqual(MenuBarSnapshot(sessions: sessions).sessionSignature, sameSessionsWithDifferentLinks.sessionSignature)
        XCTAssertNotEqual(MenuBarSnapshot(sessions: sessions).sessionSignature, removedSession.sessionSignature)
    }

    private func makeSessions(named names: [String]) -> [TmuxSession] {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        return names.map { name in
            TmuxSession(server: server, name: name, windows: 1, attached: false, createdAt: .now)
        }
    }
}
