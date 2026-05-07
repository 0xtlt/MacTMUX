import Foundation

public enum TerminalKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case terminalApp
    case iTerm2
    case warp
    case ghostty
    case cmux

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .terminalApp:
            return "Terminal.app"
        case .iTerm2:
            return "iTerm2"
        case .warp:
            return "Warp"
        case .ghostty:
            return "Ghostty"
        case .cmux:
            return "cmux"
        }
    }

    public var candidateAppPaths: [String] {
        switch self {
        case .terminalApp:
            return ["/System/Applications/Utilities/Terminal.app", "/Applications/Terminal.app"]
        case .iTerm2:
            return ["/Applications/iTerm.app", "/Applications/iTerm2.app"]
        case .warp:
            return ["/Applications/Warp.app"]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .cmux:
            return ["/Applications/cmux.app"]
        }
    }

    public var isInstalled: Bool {
        candidateAppPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
}

public protocol TerminalLaunching: Sendable {
    func open(session: TmuxSession) async throws
}

public struct TerminalLauncher: TerminalLaunching {
    private let kind: TerminalKind
    private let runner: any CommandRunning

    public init(kind: TerminalKind, runner: any CommandRunning = ProcessCommandRunner()) {
        self.kind = kind
        self.runner = runner
    }

    public func open(session: TmuxSession) async throws {
        switch kind {
        case .terminalApp:
            try await runAndCheck(Self.terminalScriptCommand(for: session))
        case .iTerm2:
            try await runAndCheck(Self.iTermScriptCommand(for: session))
        case .warp:
            try await openWarp(session: session)
        case .ghostty:
            try await runAndCheck(Self.ghosttyOpenCommand(for: session))
        case .cmux:
            try await openCmux(session: session)
        }
    }

    public static func tmuxArguments(for session: TmuxSession) -> [String] {
        [session.server.binaryPath] + TmuxCommands.serverArguments(for: session.server) + [
            "attach-session",
            "-t",
            session.name
        ]
    }

    public static func shellCommand(for session: TmuxSession) -> String {
        tmuxArguments(for: session)
            .map(shellEscape)
            .joined(separator: " ")
    }

    public static func terminalScriptCommand(for session: TmuxSession) -> CommandSpec {
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapeAppleScript(shellCommand(for: session)))"
        end tell
        """
        return CommandSpec(executable: "/usr/bin/osascript", arguments: ["-e", script])
    }

    public static func iTermScriptCommand(for session: TmuxSession) -> CommandSpec {
        let script = """
        tell application "iTerm2"
            activate
            if (count of windows) = 0 then
                create window with default profile
            else
                tell current window to create tab with default profile
            end if
            tell current session of current window
                write text "\(escapeAppleScript(shellCommand(for: session)))"
            end tell
        end tell
        """
        return CommandSpec(executable: "/usr/bin/osascript", arguments: ["-e", script])
    }

    public static func ghosttyOpenCommand(for session: TmuxSession) -> CommandSpec {
        CommandSpec(
            executable: "/usr/bin/open",
            arguments: [
                "-na",
                "Ghostty.app",
                "--args",
                "-e",
                "/bin/zsh",
                "-lc",
                shellCommand(for: session)
            ]
        )
    }

    public static func cmuxNewWorkspaceCommand(for session: TmuxSession, cmuxPath: String) -> CommandSpec {
        CommandSpec(
            executable: cmuxPath,
            arguments: [
                "new-workspace",
                "--name",
                "MacTMUX \(session.name)",
                "--cwd",
                FileManager.default.homeDirectoryForCurrentUser.path,
                "--command",
                shellCommand(for: session)
            ]
        )
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

    private func openWarp(session: TmuxSession) async throws {
        let fileURL = try writeWarpLaunchConfiguration(for: session)
        guard let encodedName = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw MacTMUXError.terminalLaunchFailed("Could not encode Warp launch configuration URL.")
        }
        try await runAndCheck(CommandSpec(executable: "/usr/bin/open", arguments: ["warp://launch/\(encodedName)"]))
    }

    private func openCmux(session: TmuxSession) async throws {
        try await runAndCheck(CommandSpec(executable: "/usr/bin/open", arguments: ["-a", "cmux"]))
        try? await Task.sleep(for: .milliseconds(600))
        guard let cmuxPath = Self.cmuxCLIPath() else {
            throw MacTMUXError.terminalLaunchFailed("cmux CLI was not found. Expected /Applications/cmux.app/Contents/Resources/bin/cmux or /usr/local/bin/cmux.")
        }
        try await runAndCheck(Self.cmuxNewWorkspaceCommand(for: session, cmuxPath: cmuxPath))
    }

    private func runAndCheck(_ command: CommandSpec) async throws {
        let result = try await runner.run(command)
        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? stdout : stderr
            throw MacTMUXError.terminalLaunchFailed(detail.isEmpty ? "Terminal launch failed." : detail)
        }
    }

    private func writeWarpLaunchConfiguration(for session: TmuxSession) throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".warp", isDirectory: true)
            .appendingPathComponent("launch_configurations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "MacTMUX-\(Self.fileSafeName(session.name)).yaml"
        let fileURL = directory.appendingPathComponent(fileName)
        let command = Self.yamlDoubleQuote(Self.shellCommand(for: session))
        let title = Self.yamlDoubleQuote(session.name)
        let contents = """
        ---
        name: \(Self.yamlDoubleQuote("MacTMUX \(session.name)"))
        windows:
          - tabs:
              - title: \(title)
                layout:
                  cwd: ""
                  commands:
                    - exec: \(command)
        """
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func cmuxCLIPath(fileManager: FileManager = .default) -> String? {
        [
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "/usr/local/bin/cmux",
            "/opt/homebrew/bin/cmux"
        ].first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func fileSafeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar).description : "-"
        }
        let collapsed = scalars.joined().replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "session" : collapsed
    }

    private static func yamlDoubleQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

public struct TerminalAppLauncher: TerminalLaunching {
    private let launcher: TerminalLauncher

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.launcher = TerminalLauncher(kind: .terminalApp, runner: runner)
    }

    public func open(session: TmuxSession) async throws {
        try await launcher.open(session: session)
    }

    public func shellCommand(for session: TmuxSession) -> String {
        TerminalLauncher.shellCommand(for: session)
    }
}
