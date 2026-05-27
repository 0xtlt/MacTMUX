import AppKit
import Foundation
import MacTMUXCore

@MainActor
enum LogTextAttributedStringBuilder {
    static let logFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let linkTextAttributes: [NSAttributedString.Key: Any] = [
        .underlineStyle: NSUnderlineStyle.single.rawValue
    ]
    static let commandLinkHoverAttributes: [NSAttributedString.Key: Any] = [
        .backgroundColor: NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18),
        .underlineStyle: NSUnderlineStyle.thick.rawValue
    ]

    private static let linkDetector: NSDataDetector = {
        do {
            return try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        } catch {
            preconditionFailure("Could not create log link detector: \(error)")
        }
    }()

    static func attributedString(for lines: [LogLine]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let text = line.text.isEmpty ? " " : line.text
            output.append(attributedString(for: text, level: line.level))
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: attributes(for: .plain)))
            }
        }
        return output
    }

    static func isAllowedLinkURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return false
        }

        return !url.absoluteString.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    static func allowedLinkURL(from link: Any) -> URL? {
        if let url = link as? URL {
            return isAllowedLinkURL(url) ? url : nil
        }

        if let url = link as? NSURL {
            let bridgedURL = url as URL
            return isAllowedLinkURL(bridgedURL) ? bridgedURL : nil
        }

        if let string = link as? String, let url = URL(string: string) {
            return isAllowedLinkURL(url) ? url : nil
        }

        return nil
    }

    static func shouldOpenLink(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.command)
    }

    private static func attributedString(for text: String, level: LogLevel) -> NSAttributedString {
        let output = NSMutableAttributedString(string: text, attributes: attributes(for: level))
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        linkDetector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match,
                  let url = match.url,
                  match.range.location != NSNotFound,
                  NSMaxRange(match.range) <= fullRange.length,
                  isAllowedDetectedLinkURL(url, visibleText: (text as NSString).substring(with: match.range)) else {
                return
            }

            output.addAttribute(.link, value: url, range: match.range)
            output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
        }
        return output
    }

    private static func attributes(for level: LogLevel) -> [NSAttributedString.Key: Any] {
        [
            .font: logFont,
            .foregroundColor: level.logTextColor
        ]
    }

    private static func isAllowedDetectedLinkURL(_ url: URL, visibleText: String) -> Bool {
        guard isAllowedLinkURL(url) else {
            return false
        }

        let lowercasedText = visibleText.lowercased()
        return lowercasedText.hasPrefix("http://") || lowercasedText.hasPrefix("https://")
    }
}

private extension LogLevel {
    var logTextColor: NSColor {
        switch self {
        case .error:
            return .systemRed
        case .warning:
            return .systemOrange
        case .success:
            return .systemGreen
        case .info:
            return .systemBlue
        case .debug:
            return .systemPurple
        case .plain:
            return .labelColor
        }
    }
}
