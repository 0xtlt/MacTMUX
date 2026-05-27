import AppKit
import MacTMUXCore
@testable import MacTMUXApp
import XCTest

@MainActor
final class LogTextAttributedStringBuilderTests: XCTestCase {
    func testLongURLUsesSingleLinkAttributeForFullRange() {
        let url = "https://example.com/logs/" + String(repeating: "very-long-segment/", count: 12) + "?trace=123"
        let text = "open \(url) now"
        let attributed = LogTextAttributedStringBuilder.attributedString(for: [
            logLine(text, level: .info)
        ])
        let range = (attributed.string as NSString).range(of: url)
        var effectiveRange = NSRange(location: NSNotFound, length: 0)

        let link = attributed.attribute(.link, at: range.location, effectiveRange: &effectiveRange) as? URL

        XCTAssertEqual(link?.absoluteString, url)
        XCTAssertEqual(effectiveRange, range)
    }

    func testMultipleURLsInOneLineAreLinkedSeparately() {
        let firstURL = "https://one.example/a"
        let secondURL = "http://two.example/b?x=1"
        let attributed = LogTextAttributedStringBuilder.attributedString(for: [
            logLine("open \(firstURL) then \(secondURL)", level: .plain)
        ])

        let links = linkRanges(in: attributed).map { range, url in
            ((attributed.string as NSString).substring(with: range), url.absoluteString)
        }

        XCTAssertEqual(links.map(\.0), [firstURL, secondURL])
        XCTAssertEqual(links.map(\.1), [firstURL, secondURL])
    }

    func testNonWebSchemesAreRejected() throws {
        let rejectedURLs = [
            "file:///tmp/mactmux.log",
            "mailto:dev@example.com",
            "ssh://example.com",
            "x-mactmux://open",
            "javascript:alert(1)",
            "data:text/plain,hello"
        ]

        for rejectedURL in rejectedURLs {
            let url = try XCTUnwrap(URL(string: rejectedURL))
            XCTAssertFalse(LogTextAttributedStringBuilder.isAllowedLinkURL(url), rejectedURL)
        }
    }

    func testUserInfoURLsAreRejected() throws {
        XCTAssertFalse(LogTextAttributedStringBuilder.isAllowedLinkURL(try XCTUnwrap(URL(string: "https://user@example.com/path"))))
        XCTAssertFalse(LogTextAttributedStringBuilder.isAllowedLinkURL(try XCTUnwrap(URL(string: "https://user:pass@example.com/path"))))
        XCTAssertTrue(LogTextAttributedStringBuilder.isAllowedLinkURL(try XCTUnwrap(URL(string: "https://example.com/path"))))
    }

    func testLinksOnlyOpenWithCommandModifier() {
        XCTAssertFalse(LogTextAttributedStringBuilder.shouldOpenLink(modifierFlags: []))
        XCTAssertFalse(LogTextAttributedStringBuilder.shouldOpenLink(modifierFlags: [.shift]))
        XCTAssertFalse(LogTextAttributedStringBuilder.shouldOpenLink(modifierFlags: [.option]))
        XCTAssertTrue(LogTextAttributedStringBuilder.shouldOpenLink(modifierFlags: [.command]))
        XCTAssertTrue(LogTextAttributedStringBuilder.shouldOpenLink(modifierFlags: [.command, .shift]))
    }

    func testCommandHoverStyleDoesNotChangeFontMetrics() {
        XCTAssertNil(LogTextAttributedStringBuilder.commandLinkHoverAttributes[.font])
        XCTAssertNotNil(LogTextAttributedStringBuilder.commandLinkHoverAttributes[.backgroundColor])
        XCTAssertEqual(
            LogTextAttributedStringBuilder.commandLinkHoverAttributes[.underlineStyle] as? Int,
            NSUnderlineStyle.thick.rawValue
        )
    }

    func testBareDomainsAreNotLinkedWithoutVisibleHTTPScheme() {
        let attributed = LogTextAttributedStringBuilder.attributedString(for: [
            logLine("open example.com or www.example.com/path", level: .plain)
        ])

        XCTAssertTrue(linkRanges(in: attributed).isEmpty)
    }

    func testURLSplitByRealNewlineIsNotMergedIntoOneLink() {
        let attributed = LogTextAttributedStringBuilder.attributedString(for: [
            logLine("partial https://exa", level: .plain),
            logLine("mple.com/path", level: .plain)
        ])
        let newlineRange = (attributed.string as NSString).range(of: "\n")

        XCTAssertNotEqual(newlineRange.location, NSNotFound)
        XCTAssertTrue(linkRanges(in: attributed).allSatisfy { range, _ in
            !NSLocationInRange(newlineRange.location, range)
        })
    }

    func testEmptyLinePlaceholderAndLevelAttributesArePreserved() {
        let attributed = LogTextAttributedStringBuilder.attributedString(for: [
            logLine("", level: .warning)
        ])

        XCTAssertEqual(attributed.string, " ")
        XCTAssertNil(attributed.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertTrue((attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemOrange) == true)
        XCTAssertTrue((attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isEqual(LogTextAttributedStringBuilder.logFont) == true)
    }

    func testLinkAttributesPreserveLogLevelColor() {
        let url = "https://example.com/failure"
        let attributed = LogTextAttributedStringBuilder.attributedString(for: [
            logLine("error at \(url)", level: .error)
        ])
        let range = (attributed.string as NSString).range(of: url)

        XCTAssertNotNil(attributed.attribute(.link, at: range.location, effectiveRange: nil))
        XCTAssertTrue((attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemRed) == true)
    }

    private func logLine(_ text: String, level: LogLevel) -> LogLine {
        LogLine(id: UUID().uuidString, text: text, level: level, sequence: 0)
    }

    private func linkRanges(in attributed: NSAttributedString) -> [(NSRange, URL)] {
        var links: [(NSRange, URL)] = []
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            if let url = value as? URL {
                links.append((range, url))
            }
        }
        return links
    }
}
