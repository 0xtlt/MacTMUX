import Foundation

public enum LogLevel: String, Codable, Sendable {
    case error
    case warning
    case success
    case info
    case debug
    case plain
}

public struct LogLine: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var text: String
    public var level: LogLevel
    public var sequence: Int

    public init(id: String, text: String, level: LogLevel, sequence: Int) {
        self.id = id
        self.text = text
        self.level = level
        self.sequence = sequence
    }
}

public struct LogMergeResult: Equatable, Sendable {
    public var insertedCount: Int
    public var replaced: Bool

    public init(insertedCount: Int, replaced: Bool = false) {
        self.insertedCount = insertedCount
        self.replaced = replaced
    }

    public var changed: Bool {
        insertedCount > 0 || replaced
    }
}

public struct LogBuffer: Equatable, Sendable {
    public private(set) var lines: [LogLine]
    public private(set) var loadedBacklogLines: Int
    public private(set) var hasMoreOlderLogs: Bool
    public let pageSize: Int
    public let maxRetainedLines: Int

    private var nextAppendSequence: Int
    private var nextPrependSequence: Int

    public init(pageSize: Int = 200, maxRetainedLines: Int = 2_000) {
        self.lines = []
        self.loadedBacklogLines = 0
        self.hasMoreOlderLogs = true
        self.pageSize = pageSize
        self.maxRetainedLines = max(1, maxRetainedLines)
        self.nextAppendSequence = 0
        self.nextPrependSequence = -1
    }

    public mutating func reset(with capturedOutput: String) -> LogMergeResult {
        let rawLines = Self.normalizedLines(from: capturedOutput)
        let retainedLines = Self.suffix(rawLines, maxCount: maxRetainedLines)
        let startSequence = rawLines.count - retainedLines.count
        lines = retainedLines.enumerated().map { index, text in
            Self.makeLine(text: text, sequence: startSequence + index)
        }
        loadedBacklogLines = pageSize
        hasMoreOlderLogs = rawLines.count >= pageSize
        resetSequenceCursors()
        return LogMergeResult(insertedCount: lines.count, replaced: true)
    }

    public mutating func appendLatest(_ capturedOutput: String) -> LogMergeResult {
        let rawLines = Self.normalizedLines(from: capturedOutput)
        guard !rawLines.isEmpty else {
            return LogMergeResult(insertedCount: 0)
        }

        guard !lines.isEmpty else {
            return reset(with: capturedOutput)
        }

        let existingTexts = lines.map(\.text)
        let overlap = Self.overlap(suffixOf: existingTexts, prefixOf: rawLines)
        if overlap == 0 {
            return reset(with: capturedOutput)
        }

        let newTexts = Array(rawLines.dropFirst(overlap))
        guard !newTexts.isEmpty else {
            return LogMergeResult(insertedCount: 0)
        }

        let newLines = newTexts.map { text in
            let line = Self.makeLine(text: text, sequence: nextAppendSequence)
            nextAppendSequence += 1
            return line
        }
        lines.append(contentsOf: newLines)
        loadedBacklogLines += newLines.count
        trimAfterAppend()
        return LogMergeResult(insertedCount: newLines.count)
    }

    public mutating func prependOlder(_ capturedOutput: String) -> LogMergeResult {
        let rawLines = Self.normalizedLines(from: capturedOutput)
        guard !rawLines.isEmpty, !lines.isEmpty else {
            hasMoreOlderLogs = false
            return LogMergeResult(insertedCount: 0)
        }

        let existingTexts = lines.map(\.text)
        let overlap = Self.overlap(suffixOf: rawLines, prefixOf: existingTexts)
        let olderTexts = Array(rawLines.dropLast(overlap))
        guard !olderTexts.isEmpty else {
            hasMoreOlderLogs = false
            return LogMergeResult(insertedCount: 0)
        }

        let startSequence = nextPrependSequence - olderTexts.count + 1
        let olderLines = olderTexts.enumerated().map { offset, text in
            Self.makeLine(text: text, sequence: startSequence + offset)
        }
        nextPrependSequence = startSequence - 1
        lines.insert(contentsOf: olderLines, at: 0)
        loadedBacklogLines += pageSize
        hasMoreOlderLogs = rawLines.count >= pageSize
        trimAfterPrepend()
        return LogMergeResult(insertedCount: olderLines.count)
    }

    public mutating func clear() {
        lines = []
        loadedBacklogLines = 0
        hasMoreOlderLogs = true
        nextAppendSequence = 0
        nextPrependSequence = -1
    }

    public static func classify(_ line: String) -> LogLevel {
        let lowercased = line.lowercased()

        if matches(lowercased, pattern: #"\b(error|err|failed|exception|fatal)\b"#) ||
            matches(lowercased, pattern: #"\b5\d\d\b"#) {
            return .error
        }

        if matches(lowercased, pattern: #"\b(warn|warning|deprecated)\b"#) ||
            matches(lowercased, pattern: #"\b4\d\d\b"#) {
            return .warning
        }

        if matches(lowercased, pattern: #"\b(success|ready|started|listening)\b"#) ||
            matches(lowercased, pattern: #"\b2\d\d\b"#) {
            return .success
        }

        if matches(lowercased, pattern: #"\b(debug|trace|verbose)\b"#) {
            return .debug
        }

        if matches(lowercased, pattern: #"\binfo\b"#) {
            return .info
        }

        return .plain
    }

    public static func normalizedLines(from output: String) -> [String] {
        var rawLines = output.components(separatedBy: .newlines)
        while rawLines.last == "" {
            rawLines.removeLast()
        }
        return rawLines
    }

    private static func makeLine(text: String, sequence: Int) -> LogLine {
        LogLine(
            id: "log-\(sequence)",
            text: text,
            level: classify(text),
            sequence: sequence
        )
    }

    private mutating func trimAfterAppend() {
        let overflow = lines.count - maxRetainedLines
        guard overflow > 0 else {
            resetSequenceCursors()
            return
        }

        lines.removeFirst(overflow)
        loadedBacklogLines = max(pageSize, loadedBacklogLines - overflow)
        resetSequenceCursors()
    }

    private mutating func trimAfterPrepend() {
        let overflow = lines.count - maxRetainedLines
        guard overflow > 0 else {
            resetSequenceCursors()
            return
        }

        lines.removeLast(overflow)
        resetSequenceCursors()
    }

    private mutating func resetSequenceCursors() {
        nextAppendSequence = lines.last.map { $0.sequence + 1 } ?? 0
        nextPrependSequence = lines.first.map { $0.sequence - 1 } ?? -1
    }

    private static func suffix(_ lines: [String], maxCount: Int) -> [String] {
        guard lines.count > maxCount else {
            return lines
        }
        return Array(lines.suffix(maxCount))
    }

    private static func overlap(suffixOf left: [String], prefixOf right: [String]) -> Int {
        let maxCount = min(left.count, right.count)
        guard maxCount > 0 else {
            return 0
        }

        for count in stride(from: maxCount, through: 1, by: -1) {
            if Array(left.suffix(count)) == Array(right.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
