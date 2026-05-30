@testable import MacTMUXApp
import XCTest

final class LinkMenuTitleFormatterTests: XCTestCase {
    func testStripsHTTPScheme() {
        XCTAssertEqual(
            LinkMenuTitleFormatter.title(for: "https://example.com/path"),
            "example.com/path"
        )
    }

    func testShortLinkIsNotTruncatedAfterSchemeStripping() {
        XCTAssertEqual(
            LinkMenuTitleFormatter.title(for: "http://localhost:3308"),
            "localhost:3308"
        )
    }

    func testLongHTTPLinkIsMiddleTrimmedAfterSchemeStripping() {
        let title = LinkMenuTitleFormatter.title(
            for: "http://localhost:3308/very/long/path/with/query",
            maximumLength: 24
        )

        XCTAssertEqual(title, "localhost:3...with/query")
        XCTAssertFalse(title.contains("http://"))
        XCTAssertEqual(title.count, 24)
    }

    func testNonHTTPStringIsMiddleTrimmedWithoutSchemeStripping() {
        let title = LinkMenuTitleFormatter.title(
            for: "file:///tmp/some/really/long/path.log",
            maximumLength: 20
        )

        XCTAssertEqual(title, "file:///t...path.log")
        XCTAssertEqual(title.count, 20)
    }
}
