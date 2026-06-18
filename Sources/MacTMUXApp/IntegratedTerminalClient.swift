import Darwin
import Foundation
import MacTMUXCore

enum IntegratedTerminalClientError: LocalizedError, Equatable {
    case alreadyAttached
    case openPTYFailed(Int32)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyAttached:
            return "A terminal client is already attached."
        case .openPTYFailed(let code):
            return "Could not open a pseudo-terminal. errno=\(code)"
        case .launchFailed(let message):
            return message
        }
    }
}

@MainActor
final class IntegratedTerminalClient {
    var onOutput: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?

    private var process: Process?
    private var masterHandle: FileHandle?
    private var slaveHandle: FileHandle?
    private(set) var attachedSession: TmuxSession?
    private let processEnvironment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        processEnvironment = environment
    }

    var isAttached: Bool {
        process != nil
    }

    func attach(
        to session: TmuxSession,
        columns: Int = TerminalViewportSizing.fallbackColumns,
        rows: Int = TerminalViewportSizing.fallbackRows
    ) throws {
        guard process == nil else {
            throw IntegratedTerminalClientError.alreadyAttached
        }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var initialSize = winsize(
            ws_row: UInt16(max(1, min(rows, Int(UInt16.max)))),
            ws_col: UInt16(max(1, min(columns, Int(UInt16.max)))),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&masterFD, &slaveFD, nil, nil, &initialSize) == 0 else {
            throw IntegratedTerminalClientError.openPTYFailed(errno)
        }

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let command = TmuxCommands.attachSession(session: session)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = Self.attachEnvironment(from: processEnvironment)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleTermination(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            try? masterHandle.close()
            try? slaveHandle.close()
            throw IntegratedTerminalClientError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.masterHandle = masterHandle
        self.slaveHandle = slaveHandle
        self.attachedSession = session
        startReading()
    }

    func write(_ data: Data) {
        guard let masterHandle else {
            return
        }
        try? masterHandle.write(contentsOf: data)
    }

    func resize(columns: Int, rows: Int) {
        var size = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        if let masterHandle {
            _ = ioctl(masterHandle.fileDescriptor, TIOCSWINSZ, &size)
        }
        if let slaveHandle {
            _ = ioctl(slaveHandle.fileDescriptor, TIOCSWINSZ, &size)
        }
    }

    func detach() {
        guard process != nil || masterHandle != nil || slaveHandle != nil else {
            return
        }

        // This intentionally terminates only the tmux client attached to this PTY.
        // It must never call `tmux kill-session`; the tmux session remains alive.
        masterHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        try? masterHandle?.close()
        try? slaveHandle?.close()
        clearState()
    }

    private func startReading() {
        masterHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            Task { @MainActor in
                self?.onOutput?(data)
            }
        }
    }

    private func handleTermination(status: Int32) {
        masterHandle?.readabilityHandler = nil
        try? masterHandle?.close()
        try? slaveHandle?.close()
        clearState()
        onTermination?(status)
    }

    private func clearState() {
        process = nil
        masterHandle = nil
        slaveHandle = nil
        attachedSession = nil
    }

    nonisolated static func attachEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = environment
        result.removeValue(forKey: "TMUX")
        result.removeValue(forKey: "TMUX_PANE")
        let term = result["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if term == nil || term == "" || term == "dumb" || term == "unknown" {
            result["TERM"] = "xterm-256color"
        }
        return result
    }
}
