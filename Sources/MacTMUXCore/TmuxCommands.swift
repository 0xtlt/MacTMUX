import Foundation

public enum TmuxCommands {
    public static func serverArguments(for server: TmuxServer) -> [String] {
        if let socketPath = server.socketPath {
            return ["-S", socketPath]
        }
        if let socketName = server.socketName {
            return ["-L", socketName]
        }
        return []
    }

    public static func listSessions(server: TmuxServer) -> CommandSpec {
        CommandSpec(
            executable: server.binaryPath,
            arguments: serverArguments(for: server) + [
                "list-sessions",
                "-F",
                "#{session_name}:::MACTMUX:::#{session_windows}:::MACTMUX:::#{session_attached}:::MACTMUX:::#{session_created}:::MACTMUX:::#{pane_pid}"
            ]
        )
    }

    public static func capturePane(session: TmuxSession, lines: Int = 200) -> CommandSpec {
        capturePane(session: session, startLine: -lines, endLine: -1)
    }

    public static func capturePane(session: TmuxSession, startLine: Int, endLine: Int) -> CommandSpec {
        CommandSpec(
            executable: session.server.binaryPath,
            arguments: serverArguments(for: session.server) + [
                "capture-pane",
                "-p",
                "-S",
                "\(startLine)",
                "-E",
                endLineArgument(endLine),
                "-t",
                session.name
            ]
        )
    }

    public static func listPanes(session: TmuxSession) -> CommandSpec {
        CommandSpec(
            executable: session.server.binaryPath,
            arguments: serverArguments(for: session.server) + [
                "list-panes",
                "-s",
                "-t",
                session.name,
                "-F",
                [
                    "#{pane_id}",
                    "#{window_index}",
                    "#{window_name}",
                    "#{window_active}",
                    "#{pane_index}",
                    "#{pane_active}",
                    "#{pane_pid}",
                    "#{pane_current_command}"
                ].joined(separator: ":::MACTMUX:::")
            ]
        )
    }

    public static func capturePane(pane: TmuxPane, startLine: Int, endLine: Int) -> CommandSpec {
        CommandSpec(
            executable: pane.server.binaryPath,
            arguments: serverArguments(for: pane.server) + [
                "capture-pane",
                "-p",
                "-S",
                "\(startLine)",
                "-E",
                endLineArgument(endLine),
                "-t",
                pane.paneID
            ]
        )
    }

    private static func endLineArgument(_ endLine: Int) -> String {
        endLine == -1 ? "-" : "\(endLine)"
    }

    public static func killSession(session: TmuxSession) -> CommandSpec {
        CommandSpec(
            executable: session.server.binaryPath,
            arguments: serverArguments(for: session.server) + [
                "kill-session",
                "-t",
                session.name
            ]
        )
    }

    public static func displayActivePaneTarget(session: TmuxSession) -> CommandSpec {
        CommandSpec(
            executable: session.server.binaryPath,
            arguments: serverArguments(for: session.server) + [
                "display-message",
                "-p",
                "-t",
                session.name,
                "#{session_name}:#{window_index}.#{pane_index}"
            ]
        )
    }

    public static func respawnPane(session: TmuxSession, paneTarget: String) -> CommandSpec {
        CommandSpec(
            executable: session.server.binaryPath,
            arguments: serverArguments(for: session.server) + [
                "respawn-pane",
                "-k",
                "-t",
                paneTarget
            ]
        )
    }
}
