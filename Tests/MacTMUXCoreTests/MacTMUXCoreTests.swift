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
        let capture = TmuxCommands.capturePane(session: session, lines: 50)

        XCTAssertEqual(list.executable, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(list.arguments.prefix(2), ["-L", "main"])
        XCTAssertEqual(kill.arguments.suffix(2), ["-t", "api; rm -rf /"])
        XCTAssertEqual(capture.arguments.suffix(4), ["-S", "-50", "-t", "api; rm -rf /"])
        XCTAssertFalse(kill.arguments.contains("sh"))
        XCTAssertFalse(kill.arguments.contains("-c"))
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
}
