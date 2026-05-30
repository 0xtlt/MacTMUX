import AppKit
import MacTMUXCore
import SwiftUI

struct SessionLinksControl: View {
    var links: [DetectedLogLink]
    var isHighlighted = false

    var body: some View {
        Group {
            if links.count == 1, let link = links.first {
                Button {
                    open(link)
                } label: {
                    iconLabel(systemImage: "link")
                }
                .buttonStyle(.plain)
                .help(link.urlString)
            } else if links.count > 1 {
                Menu {
                    ForEach(links) { link in
                        Button(menuTitle(for: link)) {
                            open(link)
                        }
                        .help(link.urlString)
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "link")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .frame(width: 34, height: 26)
                    .foregroundStyle(controlColor)
                    .background(controlBackground, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .help("\(links.count) links")
            }
        }
        .fixedSize()
    }

    private var controlColor: Color {
        isHighlighted ? .white : .secondary
    }

    private var controlBackground: Color {
        isHighlighted ? Color.white.opacity(0.16) : Color.primary.opacity(0.06)
    }

    private func iconLabel(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 28, height: 26)
            .foregroundStyle(controlColor)
            .background(controlBackground, in: RoundedRectangle(cornerRadius: 6))
    }

    private func open(_ link: DetectedLogLink) {
        guard let url = link.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func menuTitle(for link: DetectedLogLink) -> String {
        LinkMenuTitleFormatter.title(for: link.displayText)
    }
}

enum LinkMenuTitleFormatter {
    static let defaultMaximumLength = 30

    static func title(for value: String, maximumLength: Int = defaultMaximumLength) -> String {
        let displayValue = strippingHTTPScheme(from: value)
        guard displayValue.count > maximumLength else {
            return displayValue
        }
        guard maximumLength > 3 else {
            return String(displayValue.prefix(maximumLength))
        }

        let retainedLength = maximumLength - 3
        let prefixLength = (retainedLength + 1) / 2
        let suffixLength = retainedLength / 2
        return "\(displayValue.prefix(prefixLength))...\(displayValue.suffix(suffixLength))"
    }

    private static func strippingHTTPScheme(from value: String) -> String {
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("https://") {
            return String(value.dropFirst("https://".count))
        }
        if lowercased.hasPrefix("http://") {
            return String(value.dropFirst("http://".count))
        }
        return value
    }
}
