import Foundation

public protocol CommandRunning: Sendable {
    func run(_ command: CommandSpec) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: CommandSpec) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.environment = Self.minimalEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        }.value
    }

    private static func minimalEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        var result: [String: String] = [:]
        for key in ["PATH", "HOME", "USER", "SHELL", "TERM", "TMPDIR"] {
            if let value = environment[key] {
                result[key] = value
            }
        }
        if result["PATH"] == nil {
            result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        if result["TERM"] == nil {
            result["TERM"] = "xterm-256color"
        }
        return result
    }
}
