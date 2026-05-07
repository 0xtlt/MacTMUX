import Foundation

public actor TmuxClient {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func listSessions(server: TmuxServer) async throws -> [TmuxSession] {
        let result = try await runner.run(TmuxCommands.listSessions(server: server))
        if result.exitCode != 0 {
            if result.stderr.localizedCaseInsensitiveContains("no server running") {
                DiagnosticLog.write("listSessions no server server=\(server)")
                return []
            }
            throw MacTMUXError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let parsedSessions = TmuxOutputParser.parseSessions(result.stdout, server: server)
        DiagnosticLog.write("listSessions parsed=\(parsedSessions.count) names=\(parsedSessions.map(\.name).joined(separator: ",")) server=\(server)")
        return TmuxOutputParser.sortNewestFirst(parsedSessions)
    }

    public func captureLogs(session: TmuxSession) async throws -> String {
        let result = try await runner.run(TmuxCommands.capturePane(session: session))
        if result.exitCode != 0 {
            throw MacTMUXError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        DiagnosticLog.write("captureLogs session=\(session.name) bytes=\(result.stdout.utf8.count)")
        return SecretRedactor.redact(result.stdout)
    }

    public func stop(session: TmuxSession) async throws {
        let result = try await runner.run(TmuxCommands.killSession(session: session))
        if result.exitCode != 0 {
            throw MacTMUXError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func restartActivePane(session: TmuxSession) async throws {
        let targetResult = try await runner.run(TmuxCommands.displayActivePaneTarget(session: session))
        guard targetResult.exitCode == 0 else {
            throw MacTMUXError.paneTargetUnavailable(session.name)
        }
        let paneTarget = targetResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneTarget.isEmpty else {
            throw MacTMUXError.paneTargetUnavailable(session.name)
        }
        let respawnResult = try await runner.run(TmuxCommands.respawnPane(session: session, paneTarget: paneTarget))
        if respawnResult.exitCode != 0 {
            throw MacTMUXError.commandFailed(respawnResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
