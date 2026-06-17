import AppKit
@testable import MacTMUXApp
import XCTest

@MainActor
final class IntegratedTerminalViewTests: XCTestCase {
    func testViewportSizingUsesUsableFallbackBeforeSwiftUILayout() {
        let dimensions = TerminalViewportSizing.dimensions(
            for: .zero,
            characterSize: NSSize(width: 8, height: 16)
        )

        XCTAssertEqual(dimensions.columns, TerminalViewportSizing.fallbackColumns)
        XCTAssertEqual(dimensions.rows, TerminalViewportSizing.fallbackRows)
    }

    func testTerminalDocumentWidthKeepsColumnGridWhenViewportIsNarrower() {
        let width = TerminalViewportSizing.documentWidth(
            columns: 100,
            viewportWidth: 320,
            characterSize: NSSize(width: 8, height: 16),
            horizontalInset: 12
        )

        XCTAssertEqual(width, 824)
    }

    func testTerminalTextViewKeepsVisibleDocumentSizeAfterOutput() {
        let textView = TerminalTextView()
        let viewportSize = NSSize(width: 640, height: 320)

        textView.resizeDocument(to: viewportSize)
        textView.appendTerminalData(Data("visible terminal output\n".utf8))

        XCTAssertTrue(textView.string.contains("visible terminal output"))
        XCTAssertGreaterThanOrEqual(textView.frame.width, viewportSize.width)
        XCTAssertGreaterThanOrEqual(textView.frame.height, viewportSize.height)
    }

    func testTerminalTextViewUsesClippedTerminalGridLayout() {
        let textView = TerminalTextView()

        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, 0)
        XCTAssertEqual(textView.textContainer?.lineBreakMode, .byClipping)
        XCTAssertEqual(textView.layoutManager?.usesFontLeading, false)
    }

    func testTerminalTextViewPreservesTerminalViewportAfterScreenReplace() {
        let scrollView = TerminalScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let textView = TerminalTextView()
        scrollView.documentView = textView
        textView.resizeDocument(to: scrollView.contentSize)

        textView.string = (0..<80).map { "line \($0)" }.joined(separator: "\n")
        textView.resizeDocument(to: scrollView.contentSize)
        textView.scrollRangeToVisible(NSRange(location: textView.string.count, length: 0))

        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 0)
        let previousOrigin = scrollView.contentView.bounds.origin

        textView.preserveTerminalScrollOrigin(previousOrigin)

        XCTAssertEqual(scrollView.contentView.bounds.origin.x, previousOrigin.x)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, previousOrigin.y)
    }

    func testTerminalTextViewSnapshotDataMakesEmptySurfaceVisible() {
        let textView = TerminalTextView()
        textView.resizeDocument(to: NSSize(width: 640, height: 320))

        XCTAssertTrue(textView.isVisiblyEmpty)

        textView.setTerminalSnapshot(Data("\u{1B}[32mcaptured tmux screen\u{1B}[0m\n".utf8))

        XCTAssertFalse(textView.isVisiblyEmpty)
        XCTAssertTrue(textView.string.contains("captured tmux screen"))
        XCTAssertFalse(textView.string.contains("\u{1B}"))
    }

    func testTerminalScrollViewReportsViewportResizeDuringLayout() {
        let scrollView = TerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let textView = TerminalTextView()
        scrollView.documentView = textView

        var reportedSize: NSSize?
        scrollView.onViewportResize = { size in
            reportedSize = size
        }

        scrollView.layoutSubtreeIfNeeded()

        XCTAssertNotNil(reportedSize)
        XCTAssertGreaterThan(reportedSize?.width ?? 0, 0)
        XCTAssertGreaterThan(reportedSize?.height ?? 0, 0)
    }

    func testTerminalTextViewSendsPrintableKeyInput() throws {
        let textView = TerminalTextView()
        var sentData: Data?
        textView.onInput = { data in
            sentData = data
        }

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        ))

        textView.keyDown(with: event)

        XCTAssertEqual(sentData, Data("p".utf8))
    }

    func testTerminalTextViewSendsArrowKeyInput() throws {
        let textView = TerminalTextView()
        var sentData: Data?
        textView.onInput = { data in
            sentData = data
        }

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124
        ))

        textView.keyDown(with: event)

        XCTAssertEqual(sentData, Data("\u{1B}[C".utf8))
    }

    func testTerminalTextViewCanBecomeFirstResponderForInput() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TerminalTextView(frame: window.contentView?.bounds ?? .zero, textContainer: nil)
        window.contentView?.addSubview(textView)

        textView.focusForTerminalInput()

        XCTAssertTrue(window.firstResponder === textView)
    }
}
