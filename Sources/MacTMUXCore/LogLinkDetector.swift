import Foundation

public struct DetectedLogLink: Identifiable, Equatable, Codable, Sendable {
    public var urlString: String
    public var displayText: String

    public var id: String {
        urlString
    }

    public var url: URL? {
        URL(string: urlString)
    }

    public init(urlString: String, displayText: String? = nil) {
        self.urlString = urlString
        self.displayText = displayText ?? Self.displayText(for: urlString)
    }

    private static func displayText(for urlString: String) -> String {
        let maximumLength = 80
        guard urlString.count > maximumLength else {
            return urlString
        }
        return "\(urlString.prefix(maximumLength - 3))..."
    }
}

public enum LogLinkDetector {
    public static let defaultMaxCount = 8

    private static let explicitURLPattern = #"(?i)\bhttps?://[^\s<>"']+"#
    private static let localURLPattern = #"(?i)(?<![A-Za-z0-9@._:/-])(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d{1,5})?(?:/[^\s<>"']*)?"#
    private static let secretQueryNames = [
        "access_token",
        "api_key",
        "apikey",
        "auth",
        "code",
        "key",
        "secret",
        "signature",
        "token"
    ]

    public static func detectLinks(in output: String, maxCount: Int = defaultMaxCount) -> [DetectedLogLink] {
        guard maxCount > 0 else {
            return []
        }

        let sanitizedOutput = String(strippedTerminalControls(from: output).suffix(60_000))
        let candidates = linkCandidates(in: sanitizedOutput)
        var newestLinks: [DetectedLogLink] = []
        var seenURLStrings = Set<String>()

        for candidate in candidates.reversed() {
            guard let urlString = normalizedHTTPURLString(from: candidate) else {
                continue
            }
            guard seenURLStrings.insert(urlString).inserted else {
                continue
            }

            newestLinks.append(DetectedLogLink(urlString: urlString))
            if newestLinks.count == maxCount {
                break
            }
        }

        return newestLinks
    }

    private struct LinkCandidate {
        var rangeLocation: Int
        var value: String
        var hasExplicitScheme: Bool
    }

    private static func linkCandidates(in value: String) -> [LinkCandidate] {
        var candidates = matches(pattern: explicitURLPattern, in: value, hasExplicitScheme: true)
        candidates.append(contentsOf: matches(pattern: localURLPattern, in: value, hasExplicitScheme: false))
        return candidates.sorted { $0.rangeLocation < $1.rangeLocation }
    }

    private static func matches(pattern: String, in value: String, hasExplicitScheme: Bool) -> [LinkCandidate] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: value) else {
                return nil
            }
            return LinkCandidate(
                rangeLocation: match.range.location,
                value: String(value[range]),
                hasExplicitScheme: hasExplicitScheme
            )
        }
    }

    private static func normalizedHTTPURLString(from candidate: LinkCandidate) -> String? {
        let trimmedValue = trimmingTrailingPunctuation(candidate.value)
        guard !trimmedValue.isEmpty, !trimmedValue.contains("[REDACTED]") else {
            return nil
        }

        let urlString = candidate.hasExplicitScheme ? trimmedValue : "http://\(trimmedValue)"
        guard var components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              !containsSecretQueryName(components) else {
            return nil
        }

        components.scheme = scheme
        return components.url?.absoluteString
    }

    private static func containsSecretQueryName(_ components: URLComponents) -> Bool {
        guard let queryItems = components.queryItems else {
            return false
        }

        return queryItems.contains { item in
            let name = item.name.lowercased()
            return secretQueryNames.contains(name)
        }
    }

    private static func trimmingTrailingPunctuation(_ value: String) -> String {
        var trimmed = value
        while let last = trimmed.last, shouldTrimTrailingCharacter(last, in: trimmed) {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func shouldTrimTrailingCharacter(_ character: Character, in value: String) -> Bool {
        switch character {
        case ".", ",", ";", ":", "!", "?":
            return true
        case ")":
            return value.filter { $0 == ")" }.count > value.filter { $0 == "(" }.count
        case "]":
            return value.filter { $0 == "]" }.count > value.filter { $0 == "[" }.count
        case "}":
            return value.filter { $0 == "}" }.count > value.filter { $0 == "{" }.count
        default:
            return false
        }
    }

    private static func strippedTerminalControls(from value: String) -> String {
        let escape = "\u{001B}"
        let bell = "\u{0007}"
        var stripped = value
        stripped = replacing(pattern: "\(escape)\\](?s:.*?)(\(bell)|\(escape)\\\\)", in: stripped)
        stripped = replacing(pattern: "\(escape)\\[[0-?]*[ -/]*[@-~]", in: stripped)
        stripped = replacing(pattern: "\(escape)[@-Z\\\\-_]", in: stripped)

        let scalars = stripped.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || (scalar.value >= 32 && scalar.value != 127)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func replacing(pattern: String, in value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }
}
