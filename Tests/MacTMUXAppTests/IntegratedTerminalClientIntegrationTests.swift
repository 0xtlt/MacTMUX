import MacTMUXCore
@testable import MacTMUXApp
import XCTest

@MainActor
final class IntegratedTerminalClientIntegrationTests: XCTestCase {
    func testAttachEnvironmentRemovesNestedTmuxVariables() {
        let environment = IntegratedTerminalClient.attachEnvironment(from: [
            "PATH": "/usr/bin",
            "TERM": "dumb",
            "TMUX": "/tmp/tmux-501/default,123,0",
            "TMUX_PANE": "%1"
        ])

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment["TMUX"])
        XCTAssertNil(environment["TMUX_PANE"])
        XCTAssertEqual(environment["TERM"], "xterm-256color")
    }

    func testDetachTerminatesOnlyAttachClientAndKeepsTmuxSessionAlive() async throws {
        guard let tmuxPath = TmuxPathResolver.autodetect() else {
            throw XCTSkip("tmux is not available on a trusted path.")
        }

        let socketName = "mactmux-integration-\(UUID().uuidString)"
        let sessionName = "mactmux-test-\(UUID().uuidString)"
        let server = TmuxServer(binaryPath: tmuxPath, socketName: socketName)
        let session = TmuxSession(
            server: server,
            name: sessionName,
            windows: 1,
            attached: false,
            createdAt: Date()
        )

        try Self.runTmux(
            tmuxPath,
            arguments: TmuxCommands.serverArguments(for: server) + [
                "new-session",
                "-d",
                "-s",
                sessionName,
                "printf ready; sleep 30"
            ]
        )
        defer {
            try? Self.runTmux(
                tmuxPath,
                arguments: TmuxCommands.serverArguments(for: server) + [
                    "kill-session",
                    "-t",
                    sessionName
                ]
            )
        }

        let client = IntegratedTerminalClient(environment: [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "dumb",
            "TMUX": "/tmp/tmux-501/default,123,0",
            "TMUX_PANE": "%1"
        ])
        let outputExpectation = expectation(description: "attached tmux client emits pane output")
        let unexpectedTermination = expectation(description: "attached tmux client should not terminate immediately")
        unexpectedTermination.isInverted = true
        var didFulfillOutput = false
        var outputData = Data()
        client.onOutput = { data in
            outputData.append(data)
            guard !data.isEmpty, !didFulfillOutput else {
                return
            }
            didFulfillOutput = true
            outputExpectation.fulfill()
        }
        client.onTermination = { _ in
            unexpectedTermination.fulfill()
        }

        try client.attach(to: session)
        await fulfillment(of: [outputExpectation], timeout: 3)
        await fulfillment(of: [unexpectedTermination], timeout: 0.35)
        XCTAssertTrue(client.isAttached)
        let output = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertFalse(output.contains("open terminal failed"))

        client.detach()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(client.isAttached)
        try Self.runTmux(
            tmuxPath,
            arguments: TmuxCommands.serverArguments(for: server) + [
                "has-session",
                "-t",
                sessionName
            ]
        )
    }

    func testAttachedTmuxOutputRendersVisibleTerminalText() async throws {
        guard let tmuxPath = TmuxPathResolver.autodetect() else {
            throw XCTSkip("tmux is not available on a trusted path.")
        }

        let libraryPath = "\(FileManager.default.currentDirectoryPath)/Vendor/GhosttyVT/lib/libghostty-vt.dylib"
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw XCTSkip("Vendored libghostty-vt dylib is not available.")
        }

        let socketName = "mactmux-render-\(UUID().uuidString)"
        let sessionName = "mactmux-render-\(UUID().uuidString)"
        let sentinel = "mactmux-visible-output-\(UUID().uuidString)"
        let server = TmuxServer(binaryPath: tmuxPath, socketName: socketName)
        let session = TmuxSession(
            server: server,
            name: sessionName,
            windows: 1,
            attached: false,
            createdAt: Date()
        )

        try Self.runTmux(
            tmuxPath,
            arguments: TmuxCommands.serverArguments(for: server) + [
                "new-session",
                "-d",
                "-s",
                sessionName,
                "printf '\(sentinel)\\n'; sleep 30"
            ]
        )
        defer {
            try? Self.runTmux(
                tmuxPath,
                arguments: TmuxCommands.serverArguments(for: server) + [
                    "kill-session",
                    "-t",
                    sessionName
                ]
            )
        }

        let nativeBridge = try LibGhosttyVTBridge(path: libraryPath)
        let renderer = TerminalEmulatorBridge(nativeBridge: nativeBridge)
        renderer.resize(columns: 100, rows: 30)

        let client = IntegratedTerminalClient(environment: [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "dumb",
            "TMUX": "/tmp/tmux-501/default,123,0",
            "TMUX_PANE": "%1"
        ])
        let renderedExpectation = expectation(description: "tmux output renders visible terminal text")
        var renderedText = ""
        var didFulfillRenderedText = false
        client.onOutput = { data in
            let output = renderer.render(
                data: data,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular)
            )
            if output.replacesBuffer {
                renderedText = output.attributedString.string
            } else {
                renderedText += output.attributedString.string
            }

            guard renderedText.contains(sentinel), !didFulfillRenderedText else {
                return
            }
            didFulfillRenderedText = true
            renderedExpectation.fulfill()
        }

        try client.attach(to: session)
        await fulfillment(of: [renderedExpectation], timeout: 3)
        client.detach()

        XCTAssertTrue(renderedText.contains(sentinel))
    }

    func testWriteSendsInputToAttachedTmuxPane() async throws {
        guard let tmuxPath = TmuxPathResolver.autodetect() else {
            throw XCTSkip("tmux is not available on a trusted path.")
        }

        let socketName = "mactmux-input-\(UUID().uuidString)"
        let sessionName = "mactmux-input-\(UUID().uuidString)"
        let sentinel = "mactmux-input-\(UUID().uuidString)"
        let server = TmuxServer(binaryPath: tmuxPath, socketName: socketName)
        let session = TmuxSession(
            server: server,
            name: sessionName,
            windows: 1,
            attached: false,
            createdAt: Date()
        )

        try Self.runTmux(
            tmuxPath,
            arguments: TmuxCommands.serverArguments(for: server) + [
                "new-session",
                "-d",
                "-s",
                sessionName,
                "cat"
            ]
        )
        defer {
            try? Self.runTmux(
                tmuxPath,
                arguments: TmuxCommands.serverArguments(for: server) + [
                    "kill-session",
                    "-t",
                    sessionName
                ]
            )
        }

        let client = IntegratedTerminalClient(environment: [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color"
        ])
        let inputEchoExpectation = expectation(description: "attached tmux pane echoes written input")
        var outputData = Data()
        var didFulfillEcho = false
        client.onOutput = { data in
            outputData.append(data)
            let output = String(data: outputData, encoding: .utf8) ?? ""
            guard output.contains(sentinel), !didFulfillEcho else {
                return
            }
            didFulfillEcho = true
            inputEchoExpectation.fulfill()
        }

        try client.attach(to: session, columns: 100, rows: 30)
        client.write(Data("\(sentinel)\n".utf8))

        await fulfillment(of: [inputEchoExpectation], timeout: 3)
        client.detach()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains(sentinel))
    }

    private static func runTmux(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color"
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TmuxIntegrationTestError.commandFailed(
                status: process.terminationStatus,
                stderr: stderr
            )
        }
    }
}

private enum TmuxIntegrationTestError: LocalizedError {
    case commandFailed(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status, let stderr):
            return "tmux command failed with status \(status): \(stderr)"
        }
    }
}
