import Foundation

public protocol TerminalLaunching: Sendable {
    func open(session: TmuxSession) async throws
}

public struct TerminalAppLauncher: TerminalLaunching {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func open(session: TmuxSession) async throws {
        let command = shellCommand(for: session)
        let script = """
        tell application "Terminal"
            activate
            do script "\(Self.escapeAppleScript(command))"
        end tell
        """
        let result = try await runner.run(CommandSpec(executable: "/usr/bin/osascript", arguments: ["-e", script]))
        if result.exitCode != 0 {
            throw MacTMUXError.terminalLaunchFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func shellCommand(for session: TmuxSession) -> String {
        let serverArguments = TmuxCommands.serverArguments(for: session.server).map(Self.shellEscape)
        let binary = Self.shellEscape(session.server.binaryPath)
        let target = Self.shellEscape(session.name)
        return ([binary] + serverArguments + ["attach-session", "-t", target]).joined(separator: " ")
    }

    public static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
