import MacTMUXCore
@testable import MacTMUXApp
import XCTest

final class StoppedSessionSelectionResolverTests: XCTestCase {
    func testKeepsRemainingSelectedSession() {
        let sessions = makeSessions(named: ["first", "second", "third"])
        let selection = StoppedSessionSelectionResolver.resolvedSelection(
            currentSelection: [sessions[0].id, sessions[1].id],
            stoppedIDs: [sessions[0].id],
            sessions: sessions
        )

        XCTAssertEqual(selection, [sessions[1].id])
    }

    func testSelectsFirstAvailableSessionWhenStoppedSessionWasOnlySelection() {
        let sessions = makeSessions(named: ["first", "second", "third"])
        let selection = StoppedSessionSelectionResolver.resolvedSelection(
            currentSelection: [sessions[0].id],
            stoppedIDs: [sessions[0].id],
            sessions: Array(sessions.dropFirst())
        )

        XCTAssertEqual(selection, [sessions[1].id])
    }

    func testDoesNotSelectStoppedSessionFromStaleSessionList() {
        let sessions = makeSessions(named: ["first"])
        let selection = StoppedSessionSelectionResolver.resolvedSelection(
            currentSelection: [sessions[0].id],
            stoppedIDs: [sessions[0].id],
            sessions: sessions
        )

        XCTAssertTrue(selection.isEmpty)
    }

    private func makeSessions(named names: [String]) -> [TmuxSession] {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        return names.map { name in
            TmuxSession(server: server, name: name, windows: 1, attached: false, createdAt: .now)
        }
    }
}
