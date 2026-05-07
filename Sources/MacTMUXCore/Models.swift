import Foundation

public struct TmuxServer: Hashable, Codable, Sendable {
    public var binaryPath: String
    public var socketName: String?
    public var socketPath: String?

    public init(binaryPath: String, socketName: String? = nil, socketPath: String? = nil) {
        self.binaryPath = binaryPath
        self.socketName = socketName?.isEmpty == true ? nil : socketName
        self.socketPath = socketPath?.isEmpty == true ? nil : socketPath
    }
}

public struct TmuxSession: Identifiable, Hashable, Codable, Sendable {
    public var server: TmuxServer
    public var name: String
    public var windows: Int
    public var attached: Bool
    public var createdAt: Date
    public var activePanePID: Int32?

    public var id: String {
        [
            server.binaryPath,
            server.socketName ?? "",
            server.socketPath ?? "",
            name
        ].joined(separator: "\u{1F}")
    }

    public init(server: TmuxServer, name: String, windows: Int, attached: Bool, createdAt: Date, activePanePID: Int32? = nil) {
        self.server = server
        self.name = name
        self.windows = windows
        self.attached = attached
        self.createdAt = createdAt
        self.activePanePID = activePanePID
    }
}

public struct ProcessResourceMetrics: Equatable, Codable, Sendable {
    public var cpuPercent: Double
    public var residentMemoryBytes: Int64

    public init(cpuPercent: Double, residentMemoryBytes: Int64) {
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
    }

    public var formattedCPU: String {
        if cpuPercent < 10 {
            return String(format: "%.1f%%", cpuPercent)
        }
        return String(format: "%.0f%%", cpuPercent)
    }

    public var formattedMemory: String {
        let megabytes = Double(residentMemoryBytes) / 1_048_576
        if megabytes < 1024 {
            return "\(Int(megabytes.rounded())) MB"
        }
        return String(format: "%.1f GB", megabytes / 1024)
    }
}

public struct CommandSpec: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct CommandResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum MacTMUXError: LocalizedError, Equatable, Sendable {
    case tmuxNotFound
    case invalidTmuxPath(String)
    case commandFailed(String)
    case terminalLaunchFailed(String)
    case paneTargetUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .tmuxNotFound:
            return "tmux was not found. Configure a tmux binary path in Settings."
        case .invalidTmuxPath(let path):
            return "\(path) is not an executable tmux binary."
        case .commandFailed(let message):
            return message
        case .terminalLaunchFailed(let message):
            return message
        case .paneTargetUnavailable(let session):
            return "Could not resolve an active pane for \(session)."
        }
    }
}
