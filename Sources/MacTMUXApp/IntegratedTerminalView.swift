import AppKit
import MacTMUXCore
import SwiftUI

enum TerminalViewportSizing {
    static let fallbackColumns = 100
    static let fallbackRows = 30

    static func dimensions(
        for viewportSize: NSSize,
        characterSize: NSSize,
        contentInset: NSSize = .zero
    ) -> (columns: Int, rows: Int) {
        let usableWidth = max(0, viewportSize.width - contentInset.width * 2)
        let usableHeight = max(0, viewportSize.height - contentInset.height * 2)
        guard usableWidth >= characterSize.width * 8,
              usableHeight >= characterSize.height * 4 else {
            return (fallbackColumns, fallbackRows)
        }

        return (
            max(1, Int(usableWidth / characterSize.width)),
            max(1, Int(usableHeight / characterSize.height))
        )
    }

    static func documentWidth(columns: Int, viewportWidth: CGFloat, characterSize: NSSize, horizontalInset: CGFloat) -> CGFloat {
        max(
            characterSize.width,
            viewportWidth,
            CGFloat(max(1, columns)) * characterSize.width + horizontalInset * 2
        )
    }
}

struct IntegratedTerminalView: View {
    var session: TmuxSession
    var searchQuery = ""
    var enabledLogLevels = LogLevel.allCasesSet
    @State private var errorMessage: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                IntegratedTerminalSurface(
                    session: session,
                    viewportSize: geometry.size,
                    searchQuery: searchQuery,
                    enabledLogLevels: enabledLogLevels,
                    errorMessage: $errorMessage
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IntegratedTerminalSurface: NSViewRepresentable {
    var session: TmuxSession
    var viewportSize: CGSize
    var searchQuery: String
    var enabledLogLevels: Set<LogLevel>
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalScrollView {
        let textView = TerminalTextView()
        textView.onInput = { data in
            context.coordinator.write(data)
        }
        context.coordinator.textView = textView
        context.coordinator.setErrorMessage = { message in
            errorMessage = message
        }

        let scrollView = TerminalScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.onViewportResize = { [weak coordinator = context.coordinator] size in
            coordinator?.resize(to: size)
        }
        textView.resizeDocument(to: resolvedViewportSize(for: scrollView))
        textView.updateSearchQuery(searchQuery)
        textView.updateEnabledLogLevels(enabledLogLevels)

        context.coordinator.attach(to: session, viewportSize: resolvedViewportSize(for: scrollView))
        return scrollView
    }

    func updateNSView(_ scrollView: TerminalScrollView, context: Context) {
        if let textView = scrollView.documentView as? TerminalTextView {
            textView.updateSearchQuery(searchQuery)
            textView.updateEnabledLogLevels(enabledLogLevels)
        }

        context.coordinator.setErrorMessage = { message in
            errorMessage = message
        }
        scrollView.onViewportResize = { [weak coordinator = context.coordinator] size in
            coordinator?.resize(to: size)
        }

        if context.coordinator.attachedSessionID != session.id {
            context.coordinator.attach(to: session, viewportSize: resolvedViewportSize(for: scrollView))
        } else {
            context.coordinator.resize(to: resolvedViewportSize(for: scrollView))
        }
    }

    private func resolvedViewportSize(for scrollView: NSScrollView) -> NSSize {
        let geometrySize = NSSize(width: viewportSize.width, height: viewportSize.height)
        let contentSize = scrollView.contentSize
        let hasUsableGeometry = geometrySize.width >= TerminalTextView.characterSize.width * 8 &&
            geometrySize.height >= TerminalTextView.characterSize.height * 4
        let hasUsableContent = contentSize.width >= TerminalTextView.characterSize.width * 8 &&
            contentSize.height >= TerminalTextView.characterSize.height * 4

        if hasUsableContent, hasUsableGeometry {
            return NSSize(
                width: min(geometrySize.width, contentSize.width),
                height: min(geometrySize.height, contentSize.height)
            )
        }
        if hasUsableContent {
            return contentSize
        }
        if hasUsableGeometry {
            return geometrySize
        }
        return contentSize
    }

    static func dismantleNSView(_ scrollView: TerminalScrollView, coordinator: Coordinator) {
        scrollView.onViewportResize = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        let client = IntegratedTerminalClient()
        weak var textView: TerminalTextView?
        var attachedSessionID: String?
        var attachedSession: TmuxSession?
        var setErrorMessage: ((String?) -> Void)?
        private var snapshotTask: Task<Void, Never>?

        func attach(to session: TmuxSession, viewportSize: NSSize) {
            detach()
            textView?.clear()
            client.onOutput = { [weak self] data in
                self?.textView?.appendTerminalData(data)
            }
            client.onTermination = { [weak self] status in
                self?.attachedSessionID = nil
                if status != 0 {
                    self?.setErrorMessage?("Terminal client exited with status \(status).")
                }
            }

            do {
                let dimensions = TerminalViewportSizing.dimensions(
                    for: viewportSize,
                    characterSize: TerminalTextView.characterSize,
                    contentInset: TerminalTextView.gridSizingInset
                )
                try client.attach(to: session, columns: dimensions.columns, rows: dimensions.rows)
                attachedSessionID = session.id
                attachedSession = session
                setErrorMessage?(nil)
                resize(to: viewportSize)
                DispatchQueue.main.async { [weak self] in
                    self?.textView?.focusForTerminalInput()
                }
            } catch {
                attachedSessionID = nil
                attachedSession = nil
                setErrorMessage?(readableMessage(error))
            }
        }

        func write(_ data: Data) {
            client.write(data)
        }

        func resize(to size: NSSize) {
            let dimensions = TerminalViewportSizing.dimensions(
                for: size,
                characterSize: TerminalTextView.characterSize,
                contentInset: TerminalTextView.gridSizingInset
            )
            client.resize(columns: dimensions.columns, rows: dimensions.rows)
            textView?.resizeTerminal(columns: dimensions.columns, rows: dimensions.rows)
            textView?.resizeDocument(to: size)
            if let attachedSession, textView?.isVisiblyEmpty == true {
                loadInitialSnapshotIfNeeded(for: attachedSession, viewportSize: size)
            }
        }

        func detach() {
            snapshotTask?.cancel()
            snapshotTask = nil
            client.detach()
            attachedSessionID = nil
            attachedSession = nil
        }

        private func readableMessage(_ error: Error) -> String {
            if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
                return description.isEmpty ? "Unknown error." : description
            }
            return error.localizedDescription
        }

        private func loadInitialSnapshotIfNeeded(for session: TmuxSession, viewportSize: NSSize) {
            let dimensions = TerminalViewportSizing.dimensions(
                for: viewportSize,
                characterSize: TerminalTextView.characterSize,
                contentInset: TerminalTextView.gridSizingInset
            )
            guard dimensions.columns != TerminalViewportSizing.fallbackColumns ||
                    dimensions.rows != TerminalViewportSizing.fallbackRows else {
                return
            }

            let command = TmuxCommands.captureVisiblePane(session: session)
            let executable = command.executable
            let arguments = command.arguments
            let sessionID = session.id
            snapshotTask?.cancel()
            snapshotTask = Task.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else {
                    return
                }

                guard let snapshot = Self.captureSnapshotData(
                    executable: executable,
                    arguments: arguments
                ), !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    guard self?.attachedSessionID == sessionID,
                          self?.textView?.isVisiblyEmpty == true else {
                        return
                    }
                    self?.textView?.setTerminalSnapshot(snapshot)
                }
            }
        }

        nonisolated private static func captureSnapshotData(
            executable: String,
            arguments: [String]
        ) -> Data? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = IntegratedTerminalClient.attachEnvironment()

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : data
        }
    }
}

final class TerminalScrollView: NSScrollView {
    var onViewportResize: ((NSSize) -> Void)?
    private var lastReportedViewportSize: NSSize = .zero

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        (documentView as? TerminalTextView)?.focusForTerminalInput()
        super.mouseDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        notifyViewportResizeIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.notifyViewportResizeIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        notifyViewportResizeIfNeeded()
    }

    private func notifyViewportResizeIfNeeded() {
        let size = contentSize
        guard size.width > 0,
              size.height > 0,
              abs(size.width - lastReportedViewportSize.width) >= 1 ||
                abs(size.height - lastReportedViewportSize.height) >= 1 else {
            return
        }

        lastReportedViewportSize = size
        onViewportResize?(size)
    }
}

final class TerminalTextView: NSTextView {
    static let terminalFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let characterSize = "M".size(withAttributes: [.font: terminalFont])
    static let contentInset = NSSize(width: 12, height: 12)
    static var gridSizingInset: NSSize {
        NSSize(width: contentInset.width, height: contentInset.height + characterSize.height / 2)
    }
    private static let searchHighlightColor = NSColor.controlAccentColor.withAlphaComponent(0.24)

    var onInput: ((Data) -> Void)?
    private let backingTextStorage: NSTextStorage
    private let backingLayoutManager: NSLayoutManager
    private let backingTextContainer: NSTextContainer
    private lazy var emulator = TerminalEmulatorBridge()
    private var terminalBuffer = NSMutableAttributedString()
    private var viewportSize: NSSize = .zero
    private var terminalColumns = TerminalViewportSizing.fallbackColumns
    private var searchQuery = ""
    private var enabledLogLevels = LogLevel.allCasesSet
    private var searchMatchRanges: [NSRange] = []

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let textSystem = Self.makeTextSystem(textContainer: container)
        backingTextStorage = textSystem.storage
        backingLayoutManager = textSystem.layoutManager
        backingTextContainer = textSystem.textContainer
        super.init(frame: frameRect, textContainer: textSystem.textContainer)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        drawsBackground = false
        font = Self.terminalFont
        textColor = .labelColor
        linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: 0
        ]
        insertionPointColor = .clear
        textContainerInset = Self.contentInset
        textContainer?.lineFragmentPadding = 0
        textContainer?.lineBreakMode = .byClipping
        layoutManager?.usesFontLeading = false
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = true
        autoresizingMask = [.width]
        textContainer?.containerSize = NSSize(width: max(Self.characterSize.width, frame.width), height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = false
        toolTip = "Terminal renderer: \(emulator.status.rendererName)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeTextSystem(
        textContainer: NSTextContainer?
    ) -> (storage: NSTextStorage, layoutManager: NSLayoutManager, textContainer: NSTextContainer) {
        if let textContainer,
           let layoutManager = textContainer.layoutManager,
           let storage = layoutManager.textStorage {
            return (storage, layoutManager, textContainer)
        }

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: characterSize.width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byClipping
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        return (storage, layoutManager, textContainer)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        focusForTerminalInput()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        guard let data = terminalInputData(for: event) else {
            super.keyDown(with: event)
            return
        }
        onInput?(data)
    }

    func focusForTerminalInput() {
        window?.makeFirstResponder(self)
    }

    func clear() {
        terminalBuffer = NSMutableAttributedString()
        refreshDisplayedBuffer(
            preserveScrollOrigin: nil,
            scrollToBottom: false,
            scrollToFirstSearchMatch: false
        )
    }

    var isVisiblyEmpty: Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var searchMatchCount: Int {
        searchMatchRanges.count
    }

    func updateSearchQuery(_ query: String) {
        guard query != searchQuery else {
            return
        }

        searchQuery = query
        refreshSearchHighlights(scrollToFirstMatch: true)
    }

    func updateEnabledLogLevels(_ levels: Set<LogLevel>) {
        guard levels != enabledLogLevels else {
            return
        }

        let previousScrollOrigin = enclosingScrollView?.contentView.bounds.origin
        enabledLogLevels = levels
        refreshDisplayedBuffer(
            preserveScrollOrigin: previousScrollOrigin,
            scrollToBottom: false,
            scrollToFirstSearchMatch: hasActiveSearch
        )
    }

    func setTerminalSnapshot(_ data: Data) {
        clear()
        appendTerminalData(data)
    }

    func appendTerminalData(_ data: Data) {
        let previousScrollOrigin = enclosingScrollView?.contentView.bounds.origin
        let output = emulator.render(data: data, font: Self.terminalFont)
        if output.replacesBuffer {
            terminalBuffer = NSMutableAttributedString(attributedString: output.attributedString)
        } else {
            terminalBuffer.append(output.attributedString)
        }
        refreshDisplayedBuffer(
            preserveScrollOrigin: previousScrollOrigin,
            scrollToBottom: !output.replacesBuffer && !hasActiveSearch,
            scrollToFirstSearchMatch: false
        )
    }

    func preserveTerminalScrollOrigin(_ origin: NSPoint?) {
        guard let scrollView = enclosingScrollView,
              let origin else {
            return
        }

        let visibleSize = scrollView.contentView.bounds.size
        let maxX = max(0, frame.width - visibleSize.width)
        let maxY = max(0, frame.height - visibleSize.height)
        scrollView.contentView.scroll(to: NSPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func resizeTerminal(columns: Int, rows: Int) {
        terminalColumns = max(1, columns)
        emulator.resize(columns: columns, rows: rows)
        resizeDocument(to: viewportSize)
    }

    func resizeDocument(to viewportSize: NSSize) {
        self.viewportSize = viewportSize
        let viewportWidth = TerminalViewportSizing.documentWidth(
            columns: terminalColumns,
            viewportWidth: viewportSize.width,
            characterSize: Self.characterSize,
            horizontalInset: textContainerInset.width
        )
        let viewportHeight = max(Self.characterSize.height, viewportSize.height)
        minSize = NSSize(width: 0, height: viewportHeight)
        setFrameSize(NSSize(width: viewportWidth, height: max(frame.height, viewportHeight)))
        guard let textContainer else {
            setFrameSize(NSSize(width: viewportWidth, height: viewportHeight))
            return
        }

        textContainer.containerSize = NSSize(width: viewportWidth, height: CGFloat.greatestFiniteMagnitude)
        textContainer.widthTracksTextView = false
        layoutManager?.ensureLayout(for: textContainer)
        let usedHeight = layoutManager?.usedRect(for: textContainer).height ?? 0
        setFrameSize(NSSize(
            width: viewportWidth,
            height: max(viewportHeight, usedHeight + textContainerInset.height * 2)
        ))
    }

    private func terminalInputData(for event: NSEvent) -> Data? {
        let sequence: String?
        switch event.keyCode {
        case 36:
            sequence = "\r"
        case 48:
            sequence = "\t"
        case 51:
            sequence = "\u{7f}"
        case 53:
            sequence = "\u{1B}"
        case 123:
            sequence = "\u{1B}[D"
        case 124:
            sequence = "\u{1B}[C"
        case 125:
            sequence = "\u{1B}[B"
        case 126:
            sequence = "\u{1B}[A"
        default:
            sequence = event.characters
        }

        return sequence?.data(using: .utf8)
    }

    private var hasActiveSearch: Bool {
        !normalizedSearchQuery.isEmpty
    }

    private var hasActiveLogLevelFilter: Bool {
        enabledLogLevels != LogLevel.allCasesSet
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshDisplayedBuffer(
        preserveScrollOrigin: NSPoint?,
        scrollToBottom: Bool,
        scrollToFirstSearchMatch: Bool
    ) {
        textStorage?.setAttributedString(displayedTerminalBuffer())
        resizeDocument(to: viewportSize)

        if scrollToBottom {
            scrollRangeToVisible(NSRange(location: textStorage?.length ?? 0, length: 0))
        } else {
            preserveTerminalScrollOrigin(preserveScrollOrigin)
        }

        refreshSearchHighlights(scrollToFirstMatch: scrollToFirstSearchMatch)
    }

    private func displayedTerminalBuffer() -> NSAttributedString {
        guard hasActiveLogLevelFilter, terminalBuffer.length > 0 else {
            return NSAttributedString(attributedString: terminalBuffer)
        }

        let filteredBuffer = NSMutableAttributedString()
        let text = terminalBuffer.string as NSString
        var location = 0

        while location < text.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))

            let contentsRange = NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
            let lineText = text.substring(with: contentsRange)
            if enabledLogLevels.contains(LogBuffer.classify(lineText)) {
                filteredBuffer.append(terminalBuffer.attributedSubstring(from: NSRange(
                    location: lineStart,
                    length: lineEnd - lineStart
                )))
            }

            guard lineEnd > location else {
                break
            }
            location = lineEnd
        }

        return filteredBuffer
    }

    private func refreshSearchHighlights(scrollToFirstMatch: Bool) {
        clearSearchHighlights()
        searchMatchRanges = []

        let needle = normalizedSearchQuery
        guard !needle.isEmpty, backingTextStorage.length > 0 else {
            return
        }

        let haystack = backingTextStorage.string as NSString
        var remainingRange = NSRange(location: 0, length: haystack.length)

        while remainingRange.length > 0 {
            let foundRange = haystack.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: remainingRange
            )

            guard foundRange.location != NSNotFound, foundRange.length > 0 else {
                break
            }

            searchMatchRanges.append(foundRange)
            backingLayoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: Self.searchHighlightColor,
                forCharacterRange: foundRange
            )

            let nextLocation = foundRange.location + foundRange.length
            guard nextLocation < haystack.length else {
                break
            }
            remainingRange = NSRange(location: nextLocation, length: haystack.length - nextLocation)
        }

        if scrollToFirstMatch, let firstMatch = searchMatchRanges.first {
            scrollRangeToVisible(firstMatch)
        }
    }

    private func clearSearchHighlights() {
        let fullRange = NSRange(location: 0, length: backingTextStorage.length)
        guard fullRange.length > 0 else {
            return
        }

        backingLayoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string),
              let data = text.data(using: .utf8) else {
            return
        }
        onInput?(data)
    }
}
