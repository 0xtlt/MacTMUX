enum StatusBarBadgeFormatter {
    static func badgeText(sessionCount: Int, showsSessionCount: Bool) -> String? {
        guard showsSessionCount, sessionCount > 0 else {
            return nil
        }

        return badgeText(sessionCount: sessionCount)
    }

    static func badgeText(sessionCount: Int) -> String {
        guard sessionCount > 9 else {
            return "\(max(0, sessionCount))"
        }
        return "9+"
    }

    static func toolTip(sessionCount: Int) -> String {
        guard sessionCount > 0 else {
            return "MacTMUX"
        }

        let noun = sessionCount == 1 ? "session" : "sessions"
        return "MacTMUX - \(sessionCount) tmux \(noun)"
    }
}
