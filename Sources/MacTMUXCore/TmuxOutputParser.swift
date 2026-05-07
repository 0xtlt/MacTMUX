import Foundation

public enum TmuxOutputParser {
    private static let separators = [":::MACTMUX:::", "\t", "\u{1F}", "\\037"]

    public static func parseSessions(_ output: String, server: TmuxServer) -> [TmuxSession] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> TmuxSession? in
                let line = String(line)
                let parts = splitFields(line)
                guard parts.count == 4 else {
                    DiagnosticLog.write("parse skipped parts=\(parts.count) lineBytes=\(line.utf8.count)")
                    return nil
                }
                let name = parts[0]
                let windows = Int(parts[1]) ?? 0
                let attached = parts[2] == "1"
                let timestamp = TimeInterval(parts[3]) ?? 0
                return TmuxSession(
                    server: server,
                    name: name,
                    windows: windows,
                    attached: attached,
                    createdAt: Date(timeIntervalSince1970: timestamp)
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

    private static func splitFields(_ line: String) -> [String] {
        for separator in separators {
            let parts = line.components(separatedBy: separator)
            if parts.count == 4 {
                return parts
            }
        }
        let whitespaceParts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if whitespaceParts.count == 4 {
            return whitespaceParts
        }
        return [line]
    }
}
