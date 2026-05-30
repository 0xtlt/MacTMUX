import Foundation

public enum TmuxOutputParser {
    private static let separators = [":::MACTMUX:::", "\t", "\u{1F}", "\\037"]

    public static func parseSessions(_ output: String, server: TmuxServer) -> [TmuxSession] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> TmuxSession? in
                let line = String(line)
                let parts = splitFields(line)
                guard parts.count == 4 || parts.count == 5 else {
                    DiagnosticLog.write("parse skipped parts=\(parts.count) lineBytes=\(line.utf8.count)")
                    return nil
                }
                let name = parts[0]
                let windows = Int(parts[1]) ?? 0
                let attached = parts[2] == "1"
                let timestamp = TimeInterval(parts[3]) ?? 0
                let panePID = parts.count == 5 ? Int32(parts[4]) : nil
                return TmuxSession(
                    server: server,
                    name: name,
                    windows: windows,
                    attached: attached,
                    createdAt: Date(timeIntervalSince1970: timestamp),
                    activePanePID: panePID
                )
            }
    }

    public static func sortNewestFirst(_ sessions: [TmuxSession]) -> [TmuxSession] {
        sessions.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.createdAt > $1.createdAt
        }
    }

    public static func parsePanes(_ output: String, session: TmuxSession) -> [TmuxPane] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> TmuxPane? in
                let line = String(line)
                let parts = splitFields(line, expectedCounts: [8])
                guard parts.count == 8 else {
                    DiagnosticLog.write("parse pane skipped parts=\(parts.count) lineBytes=\(line.utf8.count)")
                    return nil
                }
                return TmuxPane(
                    server: session.server,
                    sessionName: session.name,
                    sessionID: session.id,
                    paneID: parts[0],
                    windowIndex: Int(parts[1]) ?? 0,
                    windowName: parts[2],
                    windowActive: parts[3] == "1",
                    paneIndex: Int(parts[4]) ?? 0,
                    paneActive: parts[5] == "1",
                    panePID: Int32(parts[6]),
                    currentCommand: parts[7]
                )
            }
            .sorted {
                if $0.windowIndex == $1.windowIndex {
                    return $0.paneIndex < $1.paneIndex
                }
                return $0.windowIndex < $1.windowIndex
            }
    }

    private static func splitFields(_ line: String) -> [String] {
        splitFields(line, expectedCounts: [4, 5])
    }

    private static func splitFields(_ line: String, expectedCounts: Set<Int>) -> [String] {
        for separator in separators {
            let parts = line.components(separatedBy: separator)
            if expectedCounts.contains(parts.count) {
                return parts
            }
        }
        let whitespaceParts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if expectedCounts.contains(whitespaceParts.count) {
            return whitespaceParts
        }
        return [line]
    }
}
