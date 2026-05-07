import Foundation

public enum SecretRedactor {
    private static let patterns = [
        #"(?i)(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key)(\s*[:=]\s*)([^\s'"]+)"#,
        #"(ghp|gho|github_pat)_[A-Za-z0-9_]{20,}"#,
        #"sk-[A-Za-z0-9_-]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#
    ]

    public static func redact(_ input: String) -> String {
        patterns.reduce(input) { current, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return current
            }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            if pattern.hasPrefix("(?i)") {
                return regex.stringByReplacingMatches(
                    in: current,
                    range: range,
                    withTemplate: "$1$2[REDACTED]"
                )
            }
            return regex.stringByReplacingMatches(
                in: current,
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
    }
}
