import AppKit
@testable import MacTMUXApp
import XCTest

@MainActor
final class TerminalEmulatorBridgeTests: XCTestCase {
    func testPlainTextFallbackStatusWhenNativeBridgeIsUnavailable() {
        let bridge = TerminalEmulatorBridge(nativeBridge: nil)

        XCTAssertEqual(bridge.status.rendererName, "Plain text fallback")
        XCTAssertNil(bridge.status.libGhosttyPath)
        XCTAssertNil(bridge.status.simdEnabled)
        XCTAssertFalse(bridge.status.isNativeBackendAvailable)
    }

    func testLibGhosttyCandidatePathsPreferExplicitEnvironmentPath() {
        let paths = LibGhosttyVTBridge.candidatePaths(
            environment: ["MACTMUX_LIBGHOSTTY_VT_PATH": "/tmp/custom-libghostty-vt.dylib"],
            bundle: Bundle.main
        )

        XCTAssertEqual(paths.first, "/tmp/custom-libghostty-vt.dylib")
        XCTAssertTrue(paths.contains { $0.hasSuffix("libghostty-vt.dylib") })
    }

    func testLibGhosttyBridgeReportsUnavailableLibrary() {
        XCTAssertThrowsError(try LibGhosttyVTBridge(path: "/tmp/mactmux-missing-libghostty-vt.dylib")) { error in
            XCTAssertEqual(
                error as? LibGhosttyVTBridge.LoadError,
                .libraryUnavailable("/tmp/mactmux-missing-libghostty-vt.dylib")
            )
        }
    }

    func testAttributedOutputMarksHTTPLinks() {
        let bridge = TerminalEmulatorBridge(nativeBridge: nil)
        let output = bridge.render(
            data: Data("Preview URL: https://example.com/app\n".utf8),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        ).attributedString
        let linkRange = (output.string as NSString).range(of: "https://example.com/app")

        XCTAssertEqual(
            output.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://example.com/app")
        )
        XCTAssertEqual(
            output.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? NSColor,
            NSColor.labelColor
        )
        XCTAssertEqual(
            output.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil) as? Int,
            0
        )
    }

    func testVendoredLibGhosttyRendersAnsiWithoutRawEscapeSequences() throws {
        let libraryPath = "/Users/thomastastet/.codex/worktrees/d0fb/MacTMUX/Vendor/GhosttyVT/lib/libghostty-vt.dylib"
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw XCTSkip("Vendored libghostty-vt dylib is not available.")
        }

        let nativeBridge = try LibGhosttyVTBridge(path: libraryPath)
        let bridge = TerminalEmulatorBridge(nativeBridge: nativeBridge)
        let rendered = bridge.render(
            data: Data("\u{1B}[31mred\u{1B}[0m\n".utf8),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        ).attributedString.string

        XCTAssertTrue(rendered.contains("red"))
        XCTAssertFalse(rendered.contains("\u{1B}"))
    }

    func testVendoredLibGhosttyPreservesAnsiForegroundColor() throws {
        let libraryPath = "/Users/thomastastet/.codex/worktrees/d0fb/MacTMUX/Vendor/GhosttyVT/lib/libghostty-vt.dylib"
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw XCTSkip("Vendored libghostty-vt dylib is not available.")
        }

        let nativeBridge = try LibGhosttyVTBridge(path: libraryPath)
        let bridge = TerminalEmulatorBridge(nativeBridge: nativeBridge)
        let output = bridge.render(
            data: Data("\u{1B}[31mred\u{1B}[0m normal\n".utf8),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        ).attributedString
        let redRange = (output.string as NSString).range(of: "red")

        let color = try XCTUnwrap(output.attribute(.foregroundColor, at: redRange.location, effectiveRange: nil) as? NSColor)
        let rgbColor = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(rgbColor.redComponent, 0.65)
        XCTAssertGreaterThan(rgbColor.redComponent, rgbColor.greenComponent + 0.2)
        XCTAssertGreaterThan(rgbColor.redComponent, rgbColor.blueComponent + 0.2)
    }

    func testVendoredLibGhosttyRendersTmuxAttachFrame() throws {
        let libraryPath = "/Users/thomastastet/.codex/worktrees/d0fb/MacTMUX/Vendor/GhosttyVT/lib/libghostty-vt.dylib"
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw XCTSkip("Vendored libghostty-vt dylib is not available.")
        }

        let nativeBridge = try LibGhosttyVTBridge(path: libraryPath)
        let bridge = TerminalEmulatorBridge(nativeBridge: nativeBridge)
        bridge.resize(columns: 100, rows: 30)

        let output = bridge.render(
            data: Data("""
            \u{1B}[?1049h\u{1B}[H\u{1B}[2J\u{1B}[?25l\u{1B}[H polaris:  {} -\u{1B}[K\r
            accessibilityLabel is recommended when scroll-box is provided\u{1B}[K\r
            14:37:19 │ \u{1B}[35m     web-frontend-backend\u{1B}[39m │ 2:37:19 PM [vite] (client) [console.warn]\u{1B}[K\r
            \u{1B}[K\r
            ──────────────────────────────────────────────────────────────────────────────────────────\u{1B}[K\r
            │\u{1B}[1m\u{1B}[7m (d) Dev status \u{1B}(B\u{1B}[m│ (a) App info │ (s) Store info │                                (q) Quit\u{1B}[K\r
            \u{1B}[K\r
             ✅ Ready, watching for changes in your app\u{1B}[K\r
            \u{1B}[K\r
             › \u{1B}[1m(p)\u{1B}(B\u{1B}[m Open app preview\u{1B}[K\r
             › \u{1B}[1m(g)\u{1B}(B\u{1B}[m Open GraphiQL (Admin API)\u{1B}[K\r
            \u{1B}[K\r
             Preview URL:\u{1B}[K\r
             https://admin.shopify.com/store/icasque-dev/apps/example?dev-console=show\u{1B}[K\r
             GraphiQL URL: http://localhost:3457/graphiql?key=secret\u{1B}[K\r
            """.utf8),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        ).attributedString.string

        XCTAssertTrue(output.contains("Ready, watching for changes in your app"))
        XCTAssertTrue(output.contains("Preview URL"))
    }

    func testVendoredLibGhosttyHandlesInteractiveRedrawBurst() throws {
        let libraryPath = "/Users/thomastastet/.codex/worktrees/d0fb/MacTMUX/Vendor/GhosttyVT/lib/libghostty-vt.dylib"
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw XCTSkip("Vendored libghostty-vt dylib is not available.")
        }

        let nativeBridge = try LibGhosttyVTBridge(path: libraryPath)
        let bridge = TerminalEmulatorBridge(nativeBridge: nativeBridge)
        bridge.resize(columns: 90, rows: 24)

        var finalOutput = NSAttributedString()
        for frame in 0..<80 {
            let row = frame % 10
            let data = Data("""
            \u{1B}[?25l\u{1B}[H\u{1B}[2J\u{1B}[1;36mMacTMUX interactive input lab\u{1B}[0m
            \u{1B}[90mArrows move · type writes · Backspace erases · q quits\u{1B}[0m

            position: x=\(String(format: "%02d", frame % 36)) y=\(String(format: "%02d", row)) repaint=\(frame)

            \u{1B}[48;5;236m  abc\u{1B}[7m \u{1B}[27m...............................\u{1B}[0m
              ....................................
              ....................................

            last keys: right down left up \(frame)
            """.utf8)
            let output = bridge.render(
                data: data,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular)
            )
            XCTAssertTrue(output.replacesBuffer)
            finalOutput = output.attributedString
        }

        XCTAssertTrue(finalOutput.string.contains("repaint=79"))
        XCTAssertTrue(finalOutput.string.contains("last keys: right down left up 79"))
        XCTAssertFalse(finalOutput.string.contains("repaint=78"))
        XCTAssertFalse(finalOutput.string.contains("\u{1B}"))
    }

    func testVendoredLibGhosttyRedrawClearsPreviousFrameText() throws {
        let libraryPath = "/Users/thomastastet/.codex/worktrees/d0fb/MacTMUX/Vendor/GhosttyVT/lib/libghostty-vt.dylib"
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw XCTSkip("Vendored libghostty-vt dylib is not available.")
        }

        let nativeBridge = try LibGhosttyVTBridge(path: libraryPath)
        let bridge = TerminalEmulatorBridge(nativeBridge: nativeBridge)
        bridge.resize(columns: 80, rows: 20)

        _ = bridge.render(
            data: Data("\u{1B}[H\u{1B}[2Jprevious-long-value\nunchanged old line\n".utf8),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let output = bridge.render(
            data: Data("\u{1B}[H\u{1B}[2Jnew\n".utf8),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        ).attributedString.string

        XCTAssertTrue(output.contains("new"))
        XCTAssertFalse(output.contains("previous-long-value"))
        XCTAssertFalse(output.contains("unchanged old line"))
    }

    func testVendoredLibGhosttyDoesNotExposeScrollbackAsCurrentScreen() throws {
        let libraryPath = "/Users/thomastastet/.codex/worktrees/d0fb/MacTMUX/Vendor/GhosttyVT/lib/libghostty-vt.dylib"
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw XCTSkip("Vendored libghostty-vt dylib is not available.")
        }

        let nativeBridge = try LibGhosttyVTBridge(path: libraryPath)
        let bridge = TerminalEmulatorBridge(nativeBridge: nativeBridge)
        bridge.resize(columns: 80, rows: 5)

        let data = Data((0..<30).map { "line-\(String(format: "%02d", $0))" }.joined(separator: "\n").utf8)
        let output = bridge.render(
            data: data,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        ).attributedString.string

        XCTAssertTrue(output.contains("line-29"))
        XCTAssertFalse(output.contains("line-00"))
        XCTAssertFalse(output.contains("line-10"))
    }

    func testVendoredLibGhosttyFormatsOnlyViewportAfterTmuxScrollRefresh() throws {
        let libraryPath = "/Users/thomastastet/.codex/worktrees/d0fb/MacTMUX/Vendor/GhosttyVT/lib/libghostty-vt.dylib"
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw XCTSkip("Vendored libghostty-vt dylib is not available.")
        }

        let nativeBridge = try LibGhosttyVTBridge(path: libraryPath)
        let bridge = TerminalEmulatorBridge(nativeBridge: nativeBridge)
        bridge.resize(columns: 100, rows: 30)

        _ = bridge.render(
            data: Self.tmuxInteractiveFrame(repaint: 108, keys: "down up down down up up down up down up down down"),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let output = bridge.render(
            data: Data("\u{1B}[1;29r\u{1B}[29S\u{1B}[1;1H".utf8)
                + Self.tmuxInteractiveFrame(repaint: 109, keys: "up down down up up down up down up down down down"),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        ).attributedString.string

        XCTAssertTrue(output.contains("repaint=109"))
        XCTAssertFalse(output.contains("repaint=108"))
        XCTAssertEqual(output.components(separatedBy: "repaint=").count - 1, 1)
    }

    private static func tmuxInteractiveFrame(repaint: Int, keys: String) -> Data {
        let lines = [
            "\u{1B}[H\u{1B}[36m\u{1B}[1mMacTMUX interactive input lab\u{1B}(B\u{1B}[m\u{1B}[K",
            "\u{1B}[90mArrows move · type writes · Enter next line · Backspace erases · q quits\u{1B}[39m\u{1B}[K",
            "\u{1B}[K",
            "position: x=00 y=09  repaint=\(repaint)\u{1B}[K",
            "\u{1B}[K",
            "  \u{1B}[32mabc\u{1B}[90m.................................\u{1B}[39m\u{1B}[K",
            "  \u{1B}[90m.....\u{1B}(B\u{1B}[m\u{1B}[32mx\u{1B}[90m..............................\u{1B}[39m\u{1B}[K",
            "  \u{1B}[32mz\u{1B}[90m...................................\u{1B}[39m\u{1B}[K",
            "  \u{1B}[90m....................................\u{1B}[39m\u{1B}[K",
            "  \u{1B}[90m....................................\u{1B}[39m\u{1B}[K",
            "  \u{1B}[90m....................................\u{1B}[39m\u{1B}[K",
            "  \u{1B}[90m....................................\u{1B}[39m\u{1B}[K",
            "  \u{1B}[90m....................................\u{1B}[39m\u{1B}[K",
            "  \u{1B}[90m....................................\u{1B}[39m\u{1B}[K",
            "\u{1B}[48;5;236m  \u{1B}[7m \u{1B}(B\u{1B}[m\u{1B}[90m\u{1B}[48;5;236m...................................\u{1B}[39m\u{1B}[49m\u{1B}[K",
            "",
            "last keys: \(keys)\u{1B}[K",
            "\u{1B}[90mTry: arrows, abc, Enter, more text, Backspace, q.\u{1B}[39m\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[K",
            "\u{1B}[30m\u{1B}[42m[mactmux-i0:node*                                            \"MacBook-Pro-de-Thomas\" 17:42 17-Jun-26\u{1B}(B\u{1B}[m"
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
