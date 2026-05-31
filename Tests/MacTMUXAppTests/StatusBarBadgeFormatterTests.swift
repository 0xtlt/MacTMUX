@testable import MacTMUXApp
import XCTest

final class StatusBarBadgeFormatterTests: XCTestCase {
    func testBadgeTextUsesCountUpToNine() {
        XCTAssertEqual(StatusBarBadgeFormatter.badgeText(sessionCount: 0), "0")
        XCTAssertEqual(StatusBarBadgeFormatter.badgeText(sessionCount: 1), "1")
        XCTAssertEqual(StatusBarBadgeFormatter.badgeText(sessionCount: 9), "9")
    }

    func testBadgeTextCapsLargeCounts() {
        XCTAssertEqual(StatusBarBadgeFormatter.badgeText(sessionCount: 10), "9+")
        XCTAssertEqual(StatusBarBadgeFormatter.badgeText(sessionCount: 42), "9+")
    }

    func testToolTipMatchesBadgeBehavior() {
        XCTAssertEqual(StatusBarBadgeFormatter.toolTip(sessionCount: 0), "MacTMUX")
        XCTAssertEqual(StatusBarBadgeFormatter.toolTip(sessionCount: 1), "MacTMUX - 1 tmux session")
        XCTAssertEqual(StatusBarBadgeFormatter.toolTip(sessionCount: 2), "MacTMUX - 2 tmux sessions")
    }
}
