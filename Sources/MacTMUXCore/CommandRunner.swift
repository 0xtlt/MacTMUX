import Foundation

public protocol CommandRunning: Sendable {
    func run(_ command: CommandSpec) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: CommandSpec) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            DiagnosticLog.write("run executable=\(command.executable) args=\(Self.safeArguments(command.arguments))")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.environment = Self.minimalEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            try process.run()
            async let stdoutData = Self.readData(from: stdoutHandle)
            async let stderrData = Self.readData(from: stderrHandle)
            process.waitUntilExit()

            let (stdoutBytes, stderrBytes) = await (stdoutData, stderrData)
            let stdout = String(data: stdoutBytes, encoding: .utf8) ?? ""
            let stderr = String(data: stderrBytes, encoding: .utf8) ?? ""

            DiagnosticLog.write("exit=\(process.terminationStatus) stdoutBytes=\(stdout.utf8.count) stderr=\(Self.trim(stderr))")
            return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        }.value
    }

    private static func readData(from handle: FileHandle) async -> Data {
        await Task.detached(priority: .userInitiated) {
            handle.readDataToEndOfFile()
        }.value
    }

    private static func minimalEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        var result: [String: String] = [:]
        for key in ["PATH", "HOME", "USER", "SHELL", "TERM"] {
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

    private static func safeArguments(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument == "capture-pane" {
                return argument
            }
            return argument.replacingOccurrences(of: "\n", with: "\\n")
        }.joined(separator: " ")
    }

    private static func trim(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 300 {
            return trimmed
        }
        return String(trimmed.prefix(300)) + "...[truncated]"
    }
}
