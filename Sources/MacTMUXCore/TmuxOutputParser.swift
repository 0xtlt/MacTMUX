import Foundation

public enum TmuxOutputParser {
    private static let separator = Character("\u{1F}")

    public static func parseSessions(_ output: String, server: TmuxServer) -> [TmuxSession] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> TmuxSession? in
                let parts = line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4 else {
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
}
