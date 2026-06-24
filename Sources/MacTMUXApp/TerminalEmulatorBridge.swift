import AppKit
import Foundation
import MacTMUXGhosttyBridge

struct TerminalEmulatorStatus: Equatable {
    var rendererName: String
    var libGhosttyPath: String?
    var simdEnabled: Bool?
    var isNativeBackendAvailable: Bool {
        libGhosttyPath != nil
    }
}

struct TerminalRenderOutput {
    var attributedString: NSAttributedString
    var replacesBuffer: Bool
}

@MainActor
final class TerminalEmulatorBridge {
    private let nativeBridge: LibGhosttyVTBridge?
    private let nativeTerminal: LibGhosttyVTTerminal?

    init(nativeBridge: LibGhosttyVTBridge? = LibGhosttyVTBridge.loadFromDefaultLocations()) {
        self.nativeBridge = nativeBridge
        if let nativeBridge {
            nativeTerminal = try? LibGhosttyVTTerminal(bridge: nativeBridge)
        } else {
            nativeTerminal = nil
        }
    }

    var status: TerminalEmulatorStatus {
        if let nativeBridge {
            return TerminalEmulatorStatus(
                rendererName: "libghostty-vt",
                libGhosttyPath: nativeBridge.libraryPath,
                simdEnabled: nativeBridge.buildInfo().simdEnabled
            )
        }

        return TerminalEmulatorStatus(
            rendererName: "Plain text fallback",
            libGhosttyPath: nil,
            simdEnabled: nil
        )
    }

    func resize(columns: Int, rows: Int) {
        nativeTerminal?.resize(columns: columns, rows: rows)
    }

    func render(data: Data, font: NSFont) -> TerminalRenderOutput {
        if let nativeTerminal,
           let vt = nativeTerminal.renderVT(data: data) {
            return TerminalRenderOutput(
                attributedString: Self.attributedTerminalVT(for: vt, font: font),
                replacesBuffer: true
            )
        }

        let rawText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let text = Self.strippedTerminalControls(from: rawText)
        return TerminalRenderOutput(
            attributedString: Self.attributedText(for: text, font: font),
            replacesBuffer: false
        )
    }

    private static func attributedText(for text: String, font: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )
        applyTerminalParagraphStyle(in: output, font: font)
        markDetectedLinks(in: output, text: text, foregroundColor: .labelColor)
        return output
    }

    private static func attributedTerminalVT(for vt: String, font: NSFont) -> NSAttributedString {
        let scalars = Array(vt.unicodeScalars)
        var index = 0
        var style = TerminalTextStyle()
        var screen = TerminalScreen()

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                index = consumeEscapeSequence(
                    in: scalars,
                    from: index,
                    style: &style,
                    screen: &screen
                )
                continue
            }

            if scalar.value == 13 {
                screen.carriageReturn()
                index += 1
                continue
            }

            if scalar.value == 10 {
                screen.lineFeed()
            } else if scalar.value == 9 {
                screen.tab(style: style)
            } else if scalar.value == 8 {
                screen.backspace()
            } else if scalar.value >= 32 {
                screen.write(String(scalar), style: style)
            }
            index += 1
        }

        let output = screen.attributedString(font: font)
        applyTerminalParagraphStyle(in: output, font: font)
        markDetectedLinks(in: output, text: output.string, foregroundColor: nil)
        return output
    }

    private static func consumeEscapeSequence(
        in scalars: [String.UnicodeScalarView.Element],
        from escapeIndex: Int,
        style: inout TerminalTextStyle,
        screen: inout TerminalScreen
    ) -> Int {
        var index = escapeIndex + 1
        guard index < scalars.count else {
            return index
        }

        let introducer = scalars[index]
        if introducer == "[" {
            index += 1
            let start = index
            while index < scalars.count {
                let value = scalars[index].value
                if value >= 0x40 && value <= 0x7E {
                    let final = scalars[index]
                    if final == "m" {
                        handleSGRParameters(String(String.UnicodeScalarView(scalars[start..<index])), style: &style)
                    } else {
                        handleCSI(
                            String(String.UnicodeScalarView(scalars[start..<index])),
                            final: final,
                            screen: &screen
                        )
                    }
                    return index + 1
                }
                index += 1
            }
            return index
        }

        if introducer == "]" {
            index += 1
            let start = index
            while index < scalars.count {
                if scalars[index].value == 0x07 {
                    handleOSC(String(String.UnicodeScalarView(scalars[start..<index])), style: &style)
                    return index + 1
                }
                if scalars[index].value == 0x1B,
                   index + 1 < scalars.count,
                   scalars[index + 1] == "\\" {
                    handleOSC(String(String.UnicodeScalarView(scalars[start..<index])), style: &style)
                    return index + 2
                }
                index += 1
            }
            return index
        }

        if introducer == "(" || introducer == ")" || introducer == "*" || introducer == "+" {
            return min(index + 2, scalars.count)
        }

        return index + 1
    }

    private static func handleCSI(
        _ value: String,
        final: String.UnicodeScalarView.Element,
        screen: inout TerminalScreen
    ) {
        let parameters = csiParameters(value)
        func parameter(_ index: Int, default defaultValue: Int) -> Int {
            guard index < parameters.count, let value = parameters[index] else {
                return defaultValue
            }
            return value
        }

        switch final {
        case "H", "f":
            screen.moveCursor(
                row: max(0, parameter(0, default: 1) - 1),
                column: max(0, parameter(1, default: 1) - 1)
            )
        case "A":
            screen.moveCursorRelative(rowDelta: -max(1, parameter(0, default: 1)), columnDelta: 0)
        case "B":
            screen.moveCursorRelative(rowDelta: max(1, parameter(0, default: 1)), columnDelta: 0)
        case "C":
            screen.moveCursorRelative(rowDelta: 0, columnDelta: max(1, parameter(0, default: 1)))
        case "D":
            screen.moveCursorRelative(rowDelta: 0, columnDelta: -max(1, parameter(0, default: 1)))
        case "E":
            screen.nextLine(count: max(1, parameter(0, default: 1)))
        case "F":
            screen.previousLine(count: max(1, parameter(0, default: 1)))
        case "G":
            screen.setColumn(max(0, parameter(0, default: 1) - 1))
        case "d":
            screen.setRow(max(0, parameter(0, default: 1) - 1))
        case "J":
            screen.eraseDisplay(mode: parameter(0, default: 0))
        case "K":
            screen.eraseLine(mode: parameter(0, default: 0))
        default:
            break
        }
    }

    private static func csiParameters(_ value: String) -> [Int?] {
        guard !value.isEmpty else {
            return []
        }

        return value
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { rawPart in
                let cleaned = rawPart.filter { $0.isNumber || $0 == "-" }
                return cleaned.isEmpty ? nil : Int(cleaned)
            }
    }

    private static func applyTerminalParagraphStyle(in output: NSMutableAttributedString, font: NSFont) {
        let fullRange = NSRange(location: 0, length: output.length)
        guard fullRange.length > 0 else {
            return
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        paragraphStyle.lineSpacing = 0
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.paragraphSpacingBefore = 0
        paragraphStyle.defaultTabInterval = " ".size(withAttributes: [.font: font]).width * 8
        output.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
    }

    private static func markDetectedLinks(
        in output: NSMutableAttributedString,
        text: String,
        foregroundColor: NSColor?
    ) {
        Self.linkDetector?.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        ).forEach { match in
            guard let url = match.url else {
                return
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .link: url,
                .underlineStyle: 0
            ]
            if let foregroundColor {
                attributes[.foregroundColor] = foregroundColor
            }
            output.addAttributes(
                attributes,
                range: match.range
            )
        }
    }

    private static func handleOSC(_ value: String, style: inout TerminalTextStyle) {
        guard value.hasPrefix("8;") else {
            return
        }

        let parts = value.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return
        }

        let urlString = String(parts[2])
        style.link = urlString.isEmpty ? nil : URL(string: urlString)
    }

    private static func handleSGRParameters(_ value: String, style: inout TerminalTextStyle) {
        let parameters = value.isEmpty ? [0] : value
            .split { $0 == ";" || $0 == ":" }
            .map { Int($0) ?? 0 }
        var index = 0

        while index < parameters.count {
            let code = parameters[index]
            switch code {
            case 0:
                style = TerminalTextStyle()
            case 1:
                style.bold = true
            case 22:
                style.bold = false
            case 4:
                style.underline = true
            case 24:
                style.underline = false
            case 7:
                style.inverse = true
            case 27:
                style.inverse = false
            case 30...37:
                style.foregroundColor = ansiColor(index: code - 30, bright: false)
            case 39:
                style.foregroundColor = nil
            case 40...47:
                style.backgroundColor = ansiColor(index: code - 40, bright: false)
            case 49:
                style.backgroundColor = nil
            case 90...97:
                style.foregroundColor = ansiColor(index: code - 90, bright: true)
            case 100...107:
                style.backgroundColor = ansiColor(index: code - 100, bright: true)
            case 38, 48:
                let parsed = parseExtendedColor(parameters: parameters, startIndex: index + 1)
                if let color = parsed.color {
                    if code == 38 {
                        style.foregroundColor = color
                    } else {
                        style.backgroundColor = color
                    }
                }
                index = parsed.nextIndex - 1
            default:
                break
            }
            index += 1
        }
    }

    private static func parseExtendedColor(parameters: [Int], startIndex: Int) -> (color: NSColor?, nextIndex: Int) {
        guard startIndex < parameters.count else {
            return (nil, startIndex)
        }

        if parameters[startIndex] == 5,
           startIndex + 1 < parameters.count {
            return (xterm256Color(parameters[startIndex + 1]), startIndex + 2)
        }

        if parameters[startIndex] == 2,
           startIndex + 3 < parameters.count {
            return (
                NSColor(
                    calibratedRed: CGFloat(max(0, min(255, parameters[startIndex + 1]))) / 255,
                    green: CGFloat(max(0, min(255, parameters[startIndex + 2]))) / 255,
                    blue: CGFloat(max(0, min(255, parameters[startIndex + 3]))) / 255,
                    alpha: 1
                ),
                startIndex + 4
            )
        }

        return (nil, startIndex + 1)
    }

    private static func ansiColor(index: Int, bright: Bool) -> NSColor {
        let normal: [(CGFloat, CGFloat, CGFloat)] = [
            (0.15, 0.15, 0.15),
            (0.78, 0.18, 0.18),
            (0.20, 0.62, 0.24),
            (0.70, 0.52, 0.16),
            (0.22, 0.42, 0.78),
            (0.62, 0.28, 0.72),
            (0.18, 0.56, 0.62),
            (0.82, 0.82, 0.82)
        ]
        let brightPalette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.45, 0.45, 0.45),
            (1.00, 0.36, 0.36),
            (0.36, 0.82, 0.42),
            (0.95, 0.76, 0.30),
            (0.40, 0.62, 1.00),
            (0.82, 0.48, 0.92),
            (0.34, 0.78, 0.86),
            (1.00, 1.00, 1.00)
        ]
        let palette = bright ? brightPalette : normal
        let rgb = palette[max(0, min(index, palette.count - 1))]
        return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    private static func xterm256Color(_ colorIndex: Int) -> NSColor {
        let index = max(0, min(255, colorIndex))
        if index < 16 {
            return ansiColor(index: index % 8, bright: index >= 8)
        }

        if index < 232 {
            let cubeIndex = index - 16
            let red = cubeIndex / 36
            let green = (cubeIndex % 36) / 6
            let blue = cubeIndex % 6
            func component(_ value: Int) -> CGFloat {
                value == 0 ? 0 : CGFloat(55 + value * 40) / 255
            }
            return NSColor(
                calibratedRed: component(red),
                green: component(green),
                blue: component(blue),
                alpha: 1
            )
        }

        let gray = CGFloat(8 + (index - 232) * 10) / 255
        return NSColor(calibratedWhite: gray, alpha: 1)
    }

    private struct TerminalTextStyle {
        var foregroundColor: NSColor?
        var backgroundColor: NSColor?
        var bold = false
        var underline = false
        var inverse = false
        var link: URL?

        func attributes(font: NSFont) -> [NSAttributedString.Key: Any] {
            let foreground = foregroundColor ?? .labelColor
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(
                    ofSize: font.pointSize,
                    weight: bold ? .semibold : .regular
                ),
                .foregroundColor: inverse ? (backgroundColor ?? .textBackgroundColor) : foreground
            ]
            let visibleBackground = inverse ? foreground : backgroundColor
            if let visibleBackground {
                attributes[.backgroundColor] = visibleBackground
            }
            if underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link {
                attributes[.link] = link
            }
            return attributes
        }
    }

    private struct TerminalScreenCell {
        var text: String
        var style: TerminalTextStyle
    }

    private struct TerminalScreen {
        private var rows: [[TerminalScreenCell?]] = [[]]
        private var row = 0
        private var column = 0

        mutating func write(_ text: String, style: TerminalTextStyle) {
            ensure(row: row, column: column)
            rows[row][column] = TerminalScreenCell(text: text, style: style)
            column += 1
        }

        mutating func tab(style: TerminalTextStyle) {
            let spaces = max(1, 8 - (column % 8))
            for _ in 0..<spaces {
                write(" ", style: style)
            }
        }

        mutating func backspace() {
            column = max(0, column - 1)
        }

        mutating func carriageReturn() {
            column = 0
        }

        mutating func lineFeed() {
            row += 1
            column = 0
            ensure(row: row, column: 0)
        }

        mutating func moveCursor(row: Int, column: Int) {
            self.row = max(0, row)
            self.column = max(0, column)
            ensure(row: self.row, column: self.column)
        }

        mutating func moveCursorRelative(rowDelta: Int, columnDelta: Int) {
            moveCursor(
                row: max(0, row + rowDelta),
                column: max(0, column + columnDelta)
            )
        }

        mutating func nextLine(count: Int) {
            moveCursor(row: row + count, column: 0)
        }

        mutating func previousLine(count: Int) {
            moveCursor(row: max(0, row - count), column: 0)
        }

        mutating func setColumn(_ column: Int) {
            moveCursor(row: row, column: column)
        }

        mutating func setRow(_ row: Int) {
            moveCursor(row: row, column: column)
        }

        mutating func eraseDisplay(mode: Int) {
            switch mode {
            case 1:
                guard !rows.isEmpty else {
                    return
                }
                for currentRow in 0..<min(row, rows.count) {
                    rows[currentRow].removeAll(keepingCapacity: true)
                }
                eraseLine(mode: 1)
            case 2, 3:
                rows = [[]]
                row = 0
                column = 0
            default:
                eraseLine(mode: 0)
                guard row + 1 < rows.count else {
                    return
                }
                for currentRow in (row + 1)..<rows.count {
                    rows[currentRow].removeAll(keepingCapacity: true)
                }
            }
        }

        mutating func eraseLine(mode: Int) {
            ensure(row: row, column: column)
            switch mode {
            case 1:
                guard !rows[row].isEmpty else {
                    return
                }
                for currentColumn in 0...min(column, rows[row].count - 1) {
                    rows[row][currentColumn] = nil
                }
            case 2:
                rows[row].removeAll(keepingCapacity: true)
            default:
                guard column < rows[row].count else {
                    return
                }
                for currentColumn in column..<rows[row].count {
                    rows[row][currentColumn] = nil
                }
            }
        }

        func attributedString(font: NSFont) -> NSMutableAttributedString {
            let output = NSMutableAttributedString()
            let lastRow = rows.lastIndex { row in
                row.contains { $0 != nil }
            } ?? 0

            for rowIndex in 0...lastRow {
                if rowIndex > 0 {
                    output.append(NSAttributedString(string: "\n", attributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor
                    ]))
                }

                let row = rowIndex < rows.count ? rows[rowIndex] : []
                let lastColumn = row.lastIndex { $0 != nil } ?? -1
                guard lastColumn >= 0 else {
                    continue
                }

                for columnIndex in 0...lastColumn {
                    if columnIndex < row.count, let cell = row[columnIndex] {
                        output.append(NSAttributedString(
                            string: cell.text,
                            attributes: cell.style.attributes(font: font)
                        ))
                    } else {
                        output.append(NSAttributedString(string: " ", attributes: [
                            .font: font,
                            .foregroundColor: NSColor.labelColor
                        ]))
                    }
                }
            }

            return output
        }

        private mutating func ensure(row: Int, column: Int) {
            while rows.count <= row {
                rows.append([])
            }
            while rows[row].count <= column {
                rows[row].append(nil)
            }
        }
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

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
        value.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }
}

struct LibGhosttyVTBuildInfo: Equatable {
    var simdEnabled: Bool?
}

final class LibGhosttyVTBridge {
    enum LoadError: LocalizedError, Equatable {
        case libraryUnavailable(String)
        case missingSymbol(String)

        var errorDescription: String? {
            switch self {
            case .libraryUnavailable(let path):
                return "Could not load libghostty-vt at \(path)."
            case .missingSymbol(let symbol):
                return "libghostty-vt is missing required symbol \(symbol)."
            }
        }
    }

    let libraryPath: String
    fileprivate let bridge: OpaquePointer

    static func loadFromDefaultLocations(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> LibGhosttyVTBridge? {
        candidatePaths(environment: environment, bundle: bundle)
            .first { fileManager.fileExists(atPath: $0) }
            .flatMap { try? LibGhosttyVTBridge(path: $0) }
    }

    static func candidatePaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> [String] {
        var paths: [String] = []
        if let explicitPath = environment["MACTMUX_LIBGHOSTTY_VT_PATH"], !explicitPath.isEmpty {
            paths.append(explicitPath)
        }

        if let privateFrameworksPath = bundle.privateFrameworksPath {
            paths.append(contentsOf: [
                "\(privateFrameworksPath)/libghostty-vt.dylib",
                "\(privateFrameworksPath)/libghostty_vt.dylib",
                "\(privateFrameworksPath)/libghostty.dylib"
            ])
        }

        paths.append(contentsOf: [
            "/opt/homebrew/lib/libghostty-vt.dylib",
            "/opt/homebrew/lib/libghostty_vt.dylib",
            "/usr/local/lib/libghostty-vt.dylib",
            "/usr/local/lib/libghostty_vt.dylib"
        ])

        return paths
    }

    init(path: String) throws {
        guard let bridge = path.withCString({ MCTGhosttyVTBridgeCreate($0) }) else {
            throw LoadError.libraryUnavailable(path)
        }
        self.libraryPath = path
        self.bridge = bridge
    }

    deinit {
        MCTGhosttyVTBridgeFree(bridge)
    }

    func buildInfo() -> LibGhosttyVTBuildInfo {
        let info = MCTGhosttyVTBridgeBuildInfo(bridge)

        return LibGhosttyVTBuildInfo(
            simdEnabled: info.available ? info.simd : nil
        )
    }
}

private final class LibGhosttyVTTerminal {
    private let terminal: OpaquePointer

    init(bridge: LibGhosttyVTBridge, columns: Int = 80, rows: Int = 24) throws {
        guard let terminal = MCTGhosttyVTTerminalCreate(
            bridge.bridge,
            UInt16(max(1, min(columns, Int(UInt16.max)))),
            UInt16(max(1, min(rows, Int(UInt16.max))))
        ) else {
            throw LibGhosttyVTBridge.LoadError.libraryUnavailable(bridge.libraryPath)
        }
        self.terminal = terminal
    }

    deinit {
        MCTGhosttyVTTerminalFree(terminal)
    }

    func resize(columns: Int, rows: Int) {
        MCTGhosttyVTTerminalResize(
            terminal,
            UInt16(max(1, min(columns, Int(UInt16.max)))),
            UInt16(max(1, min(rows, Int(UInt16.max)))),
            8,
            16
        )
    }

    func renderVT(data: Data) -> String? {
        render(data: data, format: MCT_GHOSTTY_VT_RENDER_FORMAT_VT)
    }

    private func render(data: Data, format: MCTGhosttyVTRenderFormat) -> String? {
        var outputPointer: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        let didRender = data.withUnsafeBytes { bytes in
            MCTGhosttyVTTerminalRenderFormat(
                terminal,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                data.count,
                format,
                &outputPointer,
                &outputLength
            )
        }
        guard didRender, let outputPointer else {
            return nil
        }
        defer {
            MCTGhosttyVTBufferFree(outputPointer)
        }

        return String(
            data: Data(bytes: outputPointer, count: outputLength),
            encoding: .utf8
        )
    }
}
