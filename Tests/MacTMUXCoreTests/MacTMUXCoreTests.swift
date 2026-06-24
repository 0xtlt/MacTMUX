import Foundation
import XCTest
@testable import MacTMUXCore

final class MacTMUXCoreTests: XCTestCase {
    func testParsesFormattedTmuxSessions() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let output = """
        api:::MACTMUX:::2:::MACTMUX:::1:::MACTMUX:::1778164371
        worker:::MACTMUX:::1:::MACTMUX:::0:::MACTMUX:::1778164380
        """

        let sessions = TmuxOutputParser.parseSessions(output, server: server)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].name, "api")
        XCTAssertEqual(sessions[0].windows, 2)
        XCTAssertTrue(sessions[0].attached)
        XCTAssertEqual(sessions[1].name, "worker")
        XCTAssertFalse(sessions[1].attached)
    }

    func testParsesFormattedTmuxSessionsWithActivePanePID() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let output = "api:::MACTMUX:::2:::MACTMUX:::1:::MACTMUX:::1778164371:::MACTMUX:::45520\n"

        let sessions = TmuxOutputParser.parseSessions(output, server: server)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name, "api")
        XCTAssertEqual(sessions[0].activePanePID, 45520)
    }

    func testParsesLegacyUnitSeparatorTmuxSessions() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let output = "api\u{1F}2\u{1F}1\u{1F}1778164371\n"

        let sessions = TmuxOutputParser.parseSessions(output, server: server)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name, "api")
    }

    func testParsesFormattedTmuxPanesSortedByWindowAndPane() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "api", windows: 2, attached: false, createdAt: .now)
        let output = """
        %3:::MACTMUX:::1:::MACTMUX:::queue:::MACTMUX:::1:::MACTMUX:::0:::MACTMUX:::1:::MACTMUX:::45521:::MACTMUX:::node
        %2:::MACTMUX:::0:::MACTMUX:::dev:::MACTMUX:::0:::MACTMUX:::1:::MACTMUX:::0:::MACTMUX:::45520:::MACTMUX:::zsh
        %1:::MACTMUX:::0:::MACTMUX:::dev:::MACTMUX:::0:::MACTMUX:::0:::MACTMUX:::1:::MACTMUX:::45519:::MACTMUX:::node
        """

        let panes = TmuxOutputParser.parsePanes(output, session: session)

        XCTAssertEqual(panes.map(\.paneID), ["%1", "%2", "%3"])
        XCTAssertEqual(panes[0].sessionID, session.id)
        XCTAssertEqual(panes[0].displayName, "dev 0.0")
        XCTAssertTrue(panes[0].paneActive)
        XCTAssertEqual(panes[2].windowName, "queue")
        XCTAssertTrue(panes[2].windowActive)
        XCTAssertEqual(panes[2].panePID, 45521)
        XCTAssertEqual(panes[2].currentCommand, "node")
    }

    func testSortsSessionsByCreationDateDescendingWithNameFallback() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let older = TmuxSession(server: server, name: "older", windows: 1, attached: false, createdAt: Date(timeIntervalSince1970: 10))
        let newestB = TmuxSession(server: server, name: "beta", windows: 1, attached: false, createdAt: Date(timeIntervalSince1970: 20))
        let newestA = TmuxSession(server: server, name: "alpha", windows: 1, attached: false, createdAt: Date(timeIntervalSince1970: 20))

        let sorted = TmuxOutputParser.sortNewestFirst([older, newestB, newestA])

        XCTAssertEqual(sorted.map(\.name), ["alpha", "beta", "older"])
    }

    func testBuildsTmuxCommandsAsExecutableAndArguments() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux", socketName: "main")
        let session = TmuxSession(server: server, name: "api; rm -rf /", windows: 1, attached: false, createdAt: .now)

        let list = TmuxCommands.listSessions(server: server)
        let kill = TmuxCommands.killSession(session: session)
        let attach = TmuxCommands.attachSession(session: session)
        let capture = TmuxCommands.capturePane(session: session, lines: 50)
        let visibleCapture = TmuxCommands.captureVisiblePane(session: session)
        let panes = TmuxCommands.listPanes(session: session)
        let clearHistory = TmuxCommands.clearPaneHistory(session: session, paneTarget: "api:0.0")

        XCTAssertEqual(list.executable, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(list.arguments.prefix(2), ["-L", "main"])
        XCTAssertEqual(kill.arguments.suffix(2), ["-t", "api; rm -rf /"])
        XCTAssertEqual(attach.arguments.suffix(3), ["attach-session", "-t", "api; rm -rf /"])
        XCTAssertEqual(capture.arguments.suffix(6), ["-S", "-50", "-E", "-", "-t", "api; rm -rf /"])
        XCTAssertEqual(visibleCapture.arguments.suffix(4), ["capture-pane", "-pe", "-t", "api; rm -rf /"])
        XCTAssertEqual(Array(panes.arguments.dropFirst(2).prefix(4)), ["list-panes", "-s", "-t", "api; rm -rf /"])
        XCTAssertEqual(clearHistory.arguments.suffix(3), ["clear-history", "-t", "api:0.0"])
        XCTAssertFalse(kill.arguments.contains("sh"))
        XCTAssertFalse(kill.arguments.contains("-c"))
    }

    func testRestartActivePaneClearsPaneHistoryAfterRespawn() async throws {
        let runner = RestartRecordingCommandRunner()
        let client = TmuxClient(runner: runner)
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "api", windows: 1, attached: false, createdAt: .now)

        try await client.restartActivePane(session: session)

        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.map(\.arguments.first), ["display-message", "respawn-pane", "clear-history"])
        XCTAssertEqual(commands[1].arguments.suffix(4), ["respawn-pane", "-k", "-t", "api:0.0"])
        XCTAssertEqual(commands[2].arguments.suffix(3), ["clear-history", "-t", "api:0.0"])
    }

    func testBuildsCapturePaneWithExplicitRange() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "api", windows: 1, attached: false, createdAt: .now)

        let capture = TmuxCommands.capturePane(session: session, startLine: -400, endLine: -201)

        XCTAssertEqual(capture.arguments.suffix(6), ["-S", "-400", "-E", "-201", "-t", "api"])
    }

    func testBuildsCapturePaneWithPaneTarget() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "api", windows: 1, attached: false, createdAt: .now)
        let pane = TmuxPane(
            server: server,
            sessionName: session.name,
            sessionID: session.id,
            paneID: "%7",
            windowIndex: 0,
            windowName: "dev",
            windowActive: true,
            paneIndex: 0,
            paneActive: true
        )

        let capture = TmuxCommands.capturePane(pane: pane, startLine: -80, endLine: -1)

        XCTAssertEqual(capture.arguments.suffix(6), ["-S", "-80", "-E", "-", "-t", "%7"])
    }

    func testValidatesTmuxBinaryPath() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let tmux = tempDirectory.appendingPathComponent("tmux")
        let notTmux = tempDirectory.appendingPathComponent("not-tmux")
        try Data().write(to: tmux)
        try Data().write(to: notTmux)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notTmux.path)

        XCTAssertTrue(TmuxPathResolver.isValidTmuxBinary(tmux.path))
        XCTAssertFalse(TmuxPathResolver.isValidTmuxBinary(notTmux.path))
        XCTAssertFalse(TmuxPathResolver.isValidTmuxBinary(tempDirectory.path))
    }

    func testRedactsCommonSecrets() {
        let input = """
        token=ghp_abcdefghijklmnopqrstuvwxyz123456
        password: hunter2
        OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456
        AWS_ACCESS_KEY_ID=AKIA1234567890ABCDEF
        """

        let output = SecretRedactor.redact(input)

        XCTAssertFalse(output.contains("hunter2"))
        XCTAssertFalse(output.contains("ghp_abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(output.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(output.contains("AKIA1234567890ABCDEF"))
        XCTAssertTrue(output.contains("password: [REDACTED]"))
    }

    func testDetectsHTTPLinksNewestFirst() {
        let input = """
        started at https://example.com/api
        dev server http://localhost:3000/dashboard
        """

        let links = LogLinkDetector.detectLinks(in: input)

        XCTAssertEqual(links.map(\.urlString), [
            "http://localhost:3000/dashboard",
            "https://example.com/api"
        ])
    }

    func testDetectsBareLocalhostAsHTTPLink() {
        let links = LogLinkDetector.detectLinks(in: "ready on localhost:5173/app")

        XCTAssertEqual(links.map(\.urlString), ["http://localhost:5173/app"])
    }

    func testDoesNotDetectRequestPathsWithoutBaseURL() {
        let links = LogLinkDetector.detectLinks(in: "15:48:03 Request » GET 200 /collections/news")

        XCTAssertTrue(links.isEmpty)
    }

    func testDetectsRequestPathsWithBaseURL() throws {
        let baseURL = try XCTUnwrap(URL(string: "http://localhost:9292"))
        let input = """
        15:48:03 Request » GET 200 /collections/news
        15:48:04 Request » GET 404 /products/le-faitout
        """

        let links = LogLinkDetector.detectLinks(in: input, baseURL: baseURL)

        XCTAssertEqual(links.map(\.urlString), [
            "http://localhost:9292/products/le-faitout",
            "http://localhost:9292/collections/news"
        ])
    }

    func testSkipsSecretBearingRequestPathLinks() throws {
        let baseURL = try XCTUnwrap(URL(string: "http://localhost:9292"))
        let input = """
        GET 200 /callback?token=abc
        GET 200 /safe?state=ok
        """

        let links = LogLinkDetector.detectLinks(in: input, baseURL: baseURL)

        XCTAssertEqual(links.map(\.urlString), ["http://localhost:9292/safe?state=ok"])
    }

    func testTrimsTrailingPunctuationFromDetectedLinks() {
        let links = LogLinkDetector.detectLinks(in: "open (https://example.com/path), then continue")

        XCTAssertEqual(links.map(\.urlString), ["https://example.com/path"])
    }

    func testDeduplicatesDetectedLinksKeepingNewestOccurrence() {
        let input = """
        first https://example.com/a
        second https://example.com/b
        newest https://example.com/a
        """

        let links = LogLinkDetector.detectLinks(in: input)

        XCTAssertEqual(links.map(\.urlString), [
            "https://example.com/a",
            "https://example.com/b"
        ])
    }

    func testRejectsUnsafeLinkSchemes() {
        let input = "file:///tmp/a javascript:alert(1) data:text/plain,a ftp://example.com"

        let links = LogLinkDetector.detectLinks(in: input)

        XCTAssertTrue(links.isEmpty)
    }

    func testStripsTerminalControlsBeforeDetectingLinks() {
        let input = "\u{001B}[32mhttps://example.com/ready\u{001B}[0m"

        let links = LogLinkDetector.detectLinks(in: input)

        XCTAssertEqual(links.map(\.urlString), ["https://example.com/ready"])
    }

    func testSkipsSecretBearingLinks() {
        let input = """
        https://example.com/callback?token=abc
        https://example.com/callback?access_token=abc
        https://example.com/callback?code=abc
        https://example.com/callback?value=[REDACTED]
        https://example.com/safe?state=ok
        """

        let links = LogLinkDetector.detectLinks(in: input)

        XCTAssertEqual(links.map(\.urlString), ["https://example.com/safe?state=ok"])
    }

    func testCapsDetectedLinks() {
        let input = """
        https://example.com/1
        https://example.com/2
        https://example.com/3
        """

        let links = LogLinkDetector.detectLinks(in: input, maxCount: 2)

        XCTAssertEqual(links.map(\.urlString), [
            "https://example.com/3",
            "https://example.com/2"
        ])
    }

    func testParsesProcessRecords() {
        let output = """
          100     1   0.0   1200
          101   100  12.5  20480
        """

        let records = ProcessMetricsClient.parseProcessRecords(output)

        XCTAssertEqual(records, [
            ProcessRecord(pid: 100, parentPID: 1, cpuPercent: 0.0, residentMemoryKilobytes: 1200),
            ProcessRecord(pid: 101, parentPID: 100, cpuPercent: 12.5, residentMemoryKilobytes: 20480)
        ])
    }

    func testAggregatesProcessMetricsForRootAndDescendants() {
        let records = [
            ProcessRecord(pid: 100, parentPID: 1, cpuPercent: 1.0, residentMemoryKilobytes: 1_000),
            ProcessRecord(pid: 101, parentPID: 100, cpuPercent: 2.5, residentMemoryKilobytes: 2_000),
            ProcessRecord(pid: 102, parentPID: 101, cpuPercent: 3.0, residentMemoryKilobytes: 3_000),
            ProcessRecord(pid: 200, parentPID: 1, cpuPercent: 99.0, residentMemoryKilobytes: 99_000)
        ]

        let metrics = ProcessMetricsClient.aggregate(records: records, rootPIDs: [100])

        XCTAssertEqual(metrics[100]?.cpuPercent, 6.5)
        XCTAssertEqual(metrics[100]?.residentMemoryBytes, 6_000 * 1024)
    }

    func testClassifiesLogLevels() {
        XCTAssertEqual(LogBuffer.classify("[error] failed request"), .error)
        XCTAssertEqual(LogBuffer.classify("WARN deprecated API"), .warning)
        XCTAssertEqual(LogBuffer.classify("server started status=200"), .success)
        XCTAssertEqual(LogBuffer.classify("debug trace enabled"), .debug)
        XCTAssertEqual(LogBuffer.classify("[info] loading"), .info)
        XCTAssertEqual(LogBuffer.classify("plain message"), .plain)
    }

    func testLogFilterSearchIsCaseInsensitive() {
        let lines = sampleLogLines()
        let criteria = LogFilterCriteria(query: "TIMEOUT")

        XCTAssertEqual(criteria.filter(lines).map(\.text), ["fatal upstream timeout"])
    }

    func testLogFilterErrorOnly() {
        let lines = sampleLogLines()
        let criteria = LogFilterCriteria(enabledLevels: [.error])

        XCTAssertEqual(criteria.filter(lines).map(\.level), [.error])
    }

    func testLogFilterMultipleLevels() {
        let lines = sampleLogLines()
        let criteria = LogFilterCriteria(enabledLevels: [.error, .warning])

        XCTAssertEqual(criteria.filter(lines).map(\.level), [.error, .warning])
    }

    func testLogFilterCombinesQueryAndLevels() {
        let lines = sampleLogLines()
        let criteria = LogFilterCriteria(query: "deprecated", enabledLevels: [.error, .warning])

        XCTAssertEqual(criteria.filter(lines).map(\.text), ["deprecated endpoint"])
    }

    func testLogFilterEmptyLevelSetReturnsNoLines() {
        let lines = sampleLogLines()
        let criteria = LogFilterCriteria(enabledLevels: [])

        XCTAssertTrue(criteria.filter(lines).isEmpty)
    }

    func testLogFilterDefaultReturnsAllLines() {
        let lines = sampleLogLines()
        let criteria = LogFilterCriteria()

        XCTAssertEqual(criteria.filter(lines), lines)
        XCTAssertFalse(criteria.isActive)
    }

    func testAppendsLatestLogsWithoutDuplicates() {
        var buffer = LogBuffer(pageSize: 3)
        _ = buffer.reset(with: "a\nb\nc\n")

        let result = buffer.appendLatest("b\nc\nd\ne\n")

        XCTAssertEqual(result.insertedCount, 2)
        XCTAssertFalse(result.replaced)
        XCTAssertEqual(buffer.lines.map(\.text), ["a", "b", "c", "d", "e"])
    }

    func testPrependsOlderLogsWithoutDuplicates() {
        var buffer = LogBuffer(pageSize: 3)
        _ = buffer.reset(with: "c\nd\ne\n")

        let result = buffer.prependOlder("a\nb\nc\n")

        XCTAssertEqual(result.insertedCount, 2)
        XCTAssertEqual(buffer.lines.map(\.text), ["a", "b", "c", "d", "e"])
    }

    func testLogBufferResetReplacesSessionLogs() {
        var buffer = LogBuffer(pageSize: 3)
        _ = buffer.reset(with: "old\nlogs\n")

        let result = buffer.reset(with: "new\nlogs\n")

        XCTAssertTrue(result.replaced)
        XCTAssertEqual(buffer.lines.map(\.text), ["new", "logs"])
    }

    func testLogBufferCapsRetainedLinesAfterAppend() {
        var buffer = LogBuffer(pageSize: 3, maxRetainedLines: 5)
        _ = buffer.reset(with: "a\nb\nc\n")

        let result = buffer.appendLatest("b\nc\nd\ne\nf\ng\n")

        XCTAssertEqual(result.insertedCount, 4)
        XCTAssertEqual(buffer.lines.map(\.text), ["c", "d", "e", "f", "g"])
        XCTAssertLessThanOrEqual(buffer.lines.count, 5)
    }

    func testLogBufferCapsRetainedLinesAfterPrepend() {
        var buffer = LogBuffer(pageSize: 4, maxRetainedLines: 5)
        _ = buffer.reset(with: "c\nd\ne\n")

        let result = buffer.prependOlder("0\na\nb\nc\n")

        XCTAssertEqual(result.insertedCount, 3)
        XCTAssertEqual(buffer.lines.map(\.text), ["0", "a", "b", "c", "d"])
        XCTAssertLessThanOrEqual(buffer.lines.count, 5)
    }

    func testDiagnosticLogDisabledDoesNotCreateFile() {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mactmux-test-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        DiagnosticLog.write("secret-session", environment: [:], path: tempFile.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
    }

    func testProcessCommandRunnerReadsLargeStdoutAndStderrWithoutDeadlock() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let script = tempDirectory.appendingPathComponent("large-output.sh")
        let body = """
        #!/bin/sh
        yes o | head -c 200000
        yes e | head -c 200000 1>&2
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = try await ProcessCommandRunner().run(CommandSpec(executable: script.path, arguments: []))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func testTerminalCommandEscapesSessionName() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "api'; echo bad", windows: 1, attached: false, createdAt: .now)
        let launcher = TerminalAppLauncher()

        let command = launcher.shellCommand(for: session)

        XCTAssertEqual(command, "'/opt/homebrew/bin/tmux' 'attach-session' '-t' 'api'\\''; echo bad'")
    }

    func testGhosttyCommandUsesOpenWithArguments() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux", socketPath: "/tmp/tmux-501/default")
        let session = TmuxSession(server: server, name: "api", windows: 1, attached: false, createdAt: .now)

        let command = TerminalLauncher.ghosttyOpenCommand(for: session)

        XCTAssertEqual(command.executable, "/usr/bin/open")
        XCTAssertEqual(command.arguments.prefix(5), ["-na", "Ghostty.app", "--args", "-e", "/bin/zsh"])
        XCTAssertEqual(command.arguments.suffix(2), ["-lc", "'/opt/homebrew/bin/tmux' '-S' '/tmp/tmux-501/default' 'attach-session' '-t' 'api'"])
    }

    func testCmuxCommandCreatesWorkspaceWithEscapedAttachCommand() {
        let server = TmuxServer(binaryPath: "/opt/homebrew/bin/tmux")
        let session = TmuxSession(server: server, name: "api; echo bad", windows: 1, attached: false, createdAt: .now)

        let command = TerminalLauncher.cmuxNewWorkspaceCommand(for: session, cmuxPath: "/Applications/cmux.app/Contents/Resources/bin/cmux")

        XCTAssertEqual(command.executable, "/Applications/cmux.app/Contents/Resources/bin/cmux")
        XCTAssertEqual(command.arguments.prefix(4), ["new-workspace", "--name", "MacTMUX api; echo bad", "--cwd"])
        XCTAssertTrue(command.arguments.contains("--command"))
        XCTAssertTrue(command.arguments.contains("'/opt/homebrew/bin/tmux' 'attach-session' '-t' 'api; echo bad'"))
    }

    private func sampleLogLines() -> [LogLine] {
        [
            LogLine(id: "1", text: "fatal upstream timeout", level: .error, sequence: 1),
            LogLine(id: "2", text: "deprecated endpoint", level: .warning, sequence: 2),
            LogLine(id: "3", text: "server ready", level: .success, sequence: 3),
            LogLine(id: "4", text: "debug trace enabled", level: .debug, sequence: 4),
            LogLine(id: "5", text: "plain text", level: .plain, sequence: 5)
        ]
    }
}

private actor RestartRecordingCommandRunner: CommandRunning {
    private var commands: [CommandSpec] = []

    func run(_ command: CommandSpec) async throws -> CommandResult {
        commands.append(command)
        if command.arguments.contains("display-message") {
            return CommandResult(stdout: "api:0.0\n", stderr: "", exitCode: 0)
        }
        return CommandResult(stdout: "", stderr: "", exitCode: 0)
    }

    func recordedCommands() -> [CommandSpec] {
        commands
    }
}
