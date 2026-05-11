import MacTMUXCore
import SwiftUI

struct SessionsWindowView: View {
    @EnvironmentObject private var store: MacTMUXStore
    @AppStorage("sessionsSidebarWidth") private var sidebarWidth = Double(SidebarWidth.defaultValue)
    @State private var isSidebarVisible = true
    @State private var selectedSessionIDs = Set<String>()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if isSidebarVisible {
                        sidebar
                            .frame(width: effectiveSidebarWidth(for: geometry.size.width))

                        SidebarResizeHandle(
                            sidebarWidth: $sidebarWidth,
                            availableWidth: geometry.size.width
                        )
                    }

                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
        .onAppear {
            syncSelectionWithFocusedSession()
        }
        .onChange(of: sessionIDs) { _, _ in
            pruneSelectedSessionIDs()
        }
    }

    private func effectiveSidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        SidebarWidth.clamp(CGFloat(sidebarWidth), availableWidth: availableWidth)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                ForEach(store.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Open") {
                                Task {
                                    await store.open(session)
                                }
                            }
                            Button("Restart") {
                                Task {
                                    await store.restart(session)
                                }
                            }
                            Button("Stop") {
                                Task {
                                    await store.stop(session)
                                }
                            }
                            if selectedSessions.count > 1, selectedSessionIDs.contains(session.id) {
                                Divider()
                                Button("Stop \(selectedSessions.count) Selected") {
                                    stopSelectedSessions()
                                }
                            }
                        }
                }
            }

            HStack {
                sidebarToggleButton

                Button("Refresh") {
                    Task {
                        await store.refresh()
                    }
                }
                .disabled(store.isRefreshing)

                Spacer()

                if !selectedSessions.isEmpty {
                    Button("Stop \(selectedSessions.count)", systemImage: "power") {
                        stopSelectedSessions()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)
                }

                Text("\(store.sessions.count) sessions")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var detail: some View {
        Group {
            if let session = store.selectedSession {
                SessionDetailView(session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView("Select a session", systemImage: "terminal")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if !isSidebarVisible {
                sidebarToggleButton
                    .padding(12)
            }
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                isSidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.08))
        )
        .help(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
    }

    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: {
                selectedSessionIDs
            },
            set: { newSelection in
                let previousSelection = selectedSessionIDs
                selectedSessionIDs = newSelection
                focusSessionAfterSelectionChange(from: previousSelection, to: newSelection)
            }
        )
    }

    private var selectedSessions: [TmuxSession] {
        store.sessions.filter { selectedSessionIDs.contains($0.id) }
    }

    private var sessionIDs: [String] {
        store.sessions.map(\.id)
    }

    private func focusSessionAfterSelectionChange(from previousSelection: Set<String>, to newSelection: Set<String>) {
        guard !newSelection.isEmpty else {
            Task { @MainActor in
                store.clearSelection()
            }
            return
        }

        let addedIDs = newSelection.subtracting(previousSelection)
        let focusID = store.sessions.first(where: { addedIDs.contains($0.id) })?.id
            ?? store.sessions.first(where: { newSelection.contains($0.id) })?.id

        guard let focusID, let session = store.sessions.first(where: { $0.id == focusID }) else {
            return
        }

        Task {
            await store.select(session)
        }
    }

    private func syncSelectionWithFocusedSession() {
        if selectedSessionIDs.isEmpty, let selectedSession = store.selectedSession {
            selectedSessionIDs = [selectedSession.id]
        }
        pruneSelectedSessionIDs()
    }

    private func pruneSelectedSessionIDs() {
        let validSessionIDs = Set(sessionIDs)
        selectedSessionIDs.formIntersection(validSessionIDs)
    }

    private func stopSelectedSessions() {
        let sessionsToStop = selectedSessions
        guard !sessionsToStop.isEmpty else {
            return
        }

        Task { @MainActor in
            let stoppedIDs = await store.stopSessions(sessionsToStop)
            selectedSessionIDs.subtract(stoppedIDs)
            pruneSelectedSessionIDs()
        }
    }
}

private enum SidebarWidth {
    static let defaultValue: CGFloat = 280
    static let minimum: CGFloat = 180
    static let maximum: CGFloat = 420
    static let maximumWindowRatio: CGFloat = 0.45
    static let minimumDetailWidth: CGFloat = 520

    static func clamp(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let dynamicMaximum = max(
            minimum,
            min(maximum, availableWidth * maximumWindowRatio, availableWidth - minimumDetailWidth)
        )
        return min(max(width, minimum), dynamicMaximum)
    }
}

private struct SidebarResizeHandle: View {
    @Binding var sidebarWidth: Double
    var availableWidth: CGFloat
    @State private var dragStartWidth: CGFloat?
    @State private var dragStartX: CGFloat?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            ResizeCursorArea()
            Rectangle()
                .fill(Color.clear)
                .overlay {
                    Rectangle()
                        .fill(isHovering ? Color.primary.opacity(0.28) : Color.primary.opacity(0.12))
                        .frame(width: 1)
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovering = hovering
                }
        }
        .frame(width: 8)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = SidebarWidth.clamp(CGFloat(sidebarWidth), availableWidth: availableWidth)
                        dragStartX = value.startLocation.x
                    }
                    let startWidth = dragStartWidth ?? CGFloat(sidebarWidth)
                    let startX = dragStartX ?? value.startLocation.x
                    let targetWidth = startWidth + value.location.x - startX
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        sidebarWidth = Double(SidebarWidth.clamp(targetWidth, availableWidth: availableWidth))
                    }
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    dragStartX = nil
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        sidebarWidth = Double(SidebarWidth.clamp(CGFloat(sidebarWidth), availableWidth: availableWidth))
                    }
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    sidebarWidth = Double(SidebarWidth.clamp(SidebarWidth.defaultValue, availableWidth: availableWidth))
                }
        )
        .accessibilityLabel("Resize sessions sidebar")
        .help("Drag to resize sidebar. Double-click to reset.")
    }
}

private struct ResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ResizeCursorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ResizeCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)
                if session.attached {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                }
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [
            "\(session.windows) windows",
            "created \(session.createdAt.formatted(date: .abbreviated, time: .shortened))"
        ]
        if let metricsText = store.metricsText(for: session) {
            parts.append(metricsText)
        }
        return parts.joined(separator: " · ")
    }
}

private struct SessionDetailView: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(session.windows) windows · \(session.attached ? "attached" : "detached")")
                        .foregroundStyle(.secondary)
                    if let metricsText = store.metricsText(for: session) {
                        Text(metricsText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Open", systemImage: "terminal") {
                    Task {
                        await store.open(session)
                    }
                }

                Button("Restart", systemImage: "arrow.clockwise") {
                    Task {
                        await store.restart(session)
                    }
                }

                Button("Stop", systemImage: "power") {
                    Task {
                        await store.stop(session)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent Output")
                        .font(.headline)
                    Spacer()
                    Toggle("Auto", isOn: Binding(
                        get: { store.autoRefreshLogs },
                        set: { store.autoRefreshLogs = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Button("Reload") {
                        Task {
                            await store.refreshLatestLogs(for: session)
                        }
                    }
                    .disabled(store.isLoadingLogs)
                }

                LogOutputView(session: session)
            }
            .padding()
        }
    }
}

private enum LogScrollTarget {
    static let top = "log-top"
    static let bottom = "log-bottom"
}

private enum LogTextRevisionCause {
    case initial
    case appendOrReplace
    case prependOlder
    case filterChanged
    case sessionChanged
}

private struct LogOutputView: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession

    @State private var filterCriteria = LogFilterCriteria()
    @State private var isAtBottom = true
    @State private var didInitialBottomScroll = false
    @State private var logTextRevision = 0
    @State private var logTextRevisionCause = LogTextRevisionCause.initial
    @State private var wrapsLongLogLines = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterControls

            if displayedLogLines.isEmpty {
                emptyState
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                SelectableLogTextView(
                    lines: displayedLogLines,
                    revision: logTextRevision,
                    wrapsLines: wrapsLongLogLines,
                    scrollBehavior: scrollBehavior,
                    onBottomStateChange: { isAtBottom = $0 },
                    onTopReached: { loadOlderIfNeeded() },
                    onInitialScrollCompleted: {
                        didInitialBottomScroll = true
                        isAtBottom = true
                    }
                )
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear {
            didInitialBottomScroll = false
            reviseLogs(.initial)
        }
        .onChange(of: store.logRevision) { _, _ in
            handleLogRevisionChange()
        }
        .onChange(of: session.id) { _, _ in
            didInitialBottomScroll = false
            filterCriteria = LogFilterCriteria()
            reviseLogs(.sessionChanged)
        }
        .onChange(of: filterCriteria) { _, _ in
            reviseLogs(.filterChanged)
        }
    }

    private var displayedLogLines: [LogLine] {
        filterCriteria.filter(store.logLines)
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search logs", text: $filterCriteria.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                Button("All") {
                    filterCriteria = LogFilterCriteria()
                }
                .controlSize(.small)

                Button("Errors") {
                    filterCriteria.enabledLevels = [.error]
                }
                .controlSize(.small)

                Spacer()

                Toggle("Wrap", isOn: $wrapsLongLogLines)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                if filterCriteria.isActive {
                    Text("\(displayedLogLines.count) / \(store.logLines.count) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 6) {
                ForEach(logLevelFilterItems, id: \.level) { item in
                    LogLevelFilterChip(
                        title: item.title,
                        level: item.level,
                        isEnabled: filterCriteria.enabledLevels.contains(item.level),
                        action: {
                            toggleLevel(item.level)
                        }
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        Text(emptyStateText)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyStateText: String {
        if store.logLines.isEmpty {
            return store.isLoadingSelectedInitialLogs ? "Loading logs..." : "No logs captured yet"
        }
        return "No matching logs"
    }

    private var scrollBehavior: SelectableLogTextView.ScrollBehavior {
        switch logTextRevisionCause {
        case .initial, .sessionChanged:
            return .initialBottom
        case .prependOlder:
            return .preserveAfterPrepend
        case .filterChanged:
            return didInitialBottomScroll ? .preservePosition : .initialBottom
        case .appendOrReplace:
            if !didInitialBottomScroll {
                return .initialBottom
            }
            if isAtBottom {
                return .followBottom(animated: true)
            }
            return .preservePosition
        }
    }

    private func loadOlderIfNeeded() {
        guard store.canLoadOlderLogs else {
            return
        }

        Task {
            await store.loadOlderLogs(for: session)
        }
    }

    private func handleLogRevisionChange() {
        reviseLogs(store.isLoadingOlderLogs ? .prependOlder : .appendOrReplace)
    }

    private func reviseLogs(_ cause: LogTextRevisionCause) {
        logTextRevisionCause = cause
        logTextRevision += 1
    }

    private func toggleLevel(_ level: LogLevel) {
        if filterCriteria.enabledLevels.contains(level) {
            filterCriteria.enabledLevels.remove(level)
        } else {
            filterCriteria.enabledLevels.insert(level)
        }
    }
}

private struct LogLevelFilterChip: View {
    var title: String
    var level: LogLevel
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(isEnabled ? level.displayColor : .secondary)
                .background(
                    Capsule()
                        .fill(isEnabled ? level.displayColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    Capsule()
                        .stroke(isEnabled ? level.displayColor.opacity(0.45) : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }
}

private let logLevelFilterItems: [(level: LogLevel, title: String)] = [
    (.error, "Error"),
    (.warning, "Warn"),
    (.success, "Success"),
    (.info, "Info"),
    (.debug, "Debug"),
    (.plain, "Plain")
]

private extension LogLevel {
    var displayColor: Color {
        switch self {
        case .error:
            return .red
        case .warning:
            return .orange
        case .success:
            return .green
        case .info:
            return .blue
        case .debug:
            return .purple
        case .plain:
            return .primary
        }
    }

    var nsColor: NSColor {
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

private struct SelectableLogTextView: NSViewRepresentable {
    enum ScrollBehavior: Equatable {
        case initialBottom
        case followBottom(animated: Bool)
        case preservePosition
        case preserveAfterPrepend
    }

    var lines: [LogLine]
    var revision: Int
    var wrapsLines: Bool
    var scrollBehavior: ScrollBehavior
    var onBottomStateChange: (Bool) -> Void
    var onTopReached: () -> Void
    var onInitialScrollCompleted: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onBottomStateChange: onBottomStateChange,
            onTopReached: onTopReached,
            onInitialScrollCompleted: onInitialScrollCompleted
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NotifyingScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = Self.logFont

        scrollView.documentView = textView
        configureWrapping(for: textView, in: scrollView, wrapsLines: wrapsLines)
        context.coordinator.wrapsLines = wrapsLines
        context.coordinator.lastContentWidth = scrollView.contentSize.width
        scrollView.onScroll = { [weak coordinator = context.coordinator, weak scrollView] userInitiated in
            guard let coordinator, let scrollView else {
                return
            }
            coordinator.handleScroll(
                scrollView,
                userInitiated: userInitiated || !coordinator.isProgrammaticScroll
            )
        }
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onBottomStateChange = onBottomStateChange
        context.coordinator.onTopReached = onTopReached
        context.coordinator.onInitialScrollCompleted = onInitialScrollCompleted

        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        let previousOriginY = scrollView.contentView.bounds.origin.y
        let previousDocumentHeight = textView.bounds.height
        let selectedRanges = textView.selectedRanges
        let wrappingChanged = context.coordinator.wrapsLines != wrapsLines
        let contentWidthChanged = abs(context.coordinator.lastContentWidth - scrollView.contentSize.width) > 0.5

        if wrappingChanged || (wrapsLines && contentWidthChanged) {
            configureWrapping(for: textView, in: scrollView, wrapsLines: wrapsLines)
            context.coordinator.wrapsLines = wrapsLines
            context.coordinator.lastContentWidth = scrollView.contentSize.width
            textView.sizeToFit()
        }

        if context.coordinator.lastRevision != revision {
            textView.textStorage?.setAttributedString(Self.attributedString(for: lines))
            textView.selectedRanges = Self.validSelectionRanges(selectedRanges, textLength: textView.string.utf16.count)
            textView.sizeToFit()
            context.coordinator.lastRevision = revision
            applyScrollBehavior(
                scrollView: scrollView,
                textView: textView,
                previousOriginY: previousOriginY,
                previousDocumentHeight: previousDocumentHeight,
                coordinator: context.coordinator
            )
        } else if wrappingChanged || (wrapsLines && contentWidthChanged) {
            applyScrollBehavior(
                scrollView: scrollView,
                textView: textView,
                previousOriginY: previousOriginY,
                previousDocumentHeight: previousDocumentHeight,
                coordinator: context.coordinator
            )
        }

        context.coordinator.handleScroll(scrollView, userInitiated: false)
    }

    private func configureWrapping(for textView: NSTextView, in scrollView: NSScrollView, wrapsLines: Bool) {
        scrollView.hasHorizontalScroller = !wrapsLines
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.lineBreakMode = wrapsLines ? .byCharWrapping : .byClipping
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = wrapsLines ? [.width] : []
        if wrapsLines {
            let contentWidth = max(1, scrollView.contentSize.width)
            textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
            textView.setFrameSize(NSSize(width: contentWidth, height: max(textView.frame.height, scrollView.contentSize.height)))
        } else {
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        if let textContainer = textView.textContainer {
            textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.string.utf16.count), actualCharacterRange: nil)
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        if wrapsLines {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
        }
    }

    private func applyScrollBehavior(
        scrollView: NSScrollView,
        textView: NSTextView,
        previousOriginY: CGFloat,
        previousDocumentHeight: CGFloat,
        coordinator: Coordinator
    ) {
        switch scrollBehavior {
        case .initialBottom:
            coordinator.scrollToBottom(scrollView, animated: false)
            DispatchQueue.main.async {
                coordinator.onInitialScrollCompleted()
            }
        case .followBottom(let animated):
            coordinator.scrollToBottom(scrollView, animated: animated)
        case .preservePosition:
            coordinator.scroll(scrollView, toY: previousOriginY, animated: false)
        case .preserveAfterPrepend:
            let newDocumentHeight = textView.bounds.height
            let delta = max(0, newDocumentHeight - previousDocumentHeight)
            coordinator.scroll(scrollView, toY: previousOriginY + delta, animated: false)
        }
    }

    private static func attributedString(for lines: [LogLine]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let text = line.text.isEmpty ? " " : line.text
            output.append(NSAttributedString(string: text, attributes: attributes(for: line.level)))
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: attributes(for: .plain)))
            }
        }
        return output
    }

    private static func attributes(for level: LogLevel) -> [NSAttributedString.Key: Any] {
        [
            .font: logFont,
            .foregroundColor: level.nsColor
        ]
    }

    private static func validSelectionRanges(_ ranges: [NSValue], textLength: Int) -> [NSValue] {
        let validRanges = ranges.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location != NSNotFound,
                  range.location <= textLength,
                  NSMaxRange(range) <= textLength else {
                return nil
            }
            return value
        }
        return validRanges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : validRanges
    }

    private static let logFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    @MainActor
    final class Coordinator {
        var onBottomStateChange: (Bool) -> Void
        var onTopReached: () -> Void
        var onInitialScrollCompleted: () -> Void
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var lastRevision = -1
        var wrapsLines = false
        var lastContentWidth: CGFloat = 0
        var isProgrammaticScroll = false
        private var isAtTop = false

        init(
            onBottomStateChange: @escaping (Bool) -> Void,
            onTopReached: @escaping () -> Void,
            onInitialScrollCompleted: @escaping () -> Void
        ) {
            self.onBottomStateChange = onBottomStateChange
            self.onTopReached = onTopReached
            self.onInitialScrollCompleted = onInitialScrollCompleted
        }

        func handleScroll(_ scrollView: NSScrollView, userInitiated: Bool) {
            let bounds = scrollView.contentView.bounds
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let visibleHeight = bounds.height
            let maxY = max(0, documentHeight - visibleHeight)
            let currentY = max(0, bounds.origin.y)
            let atBottom = maxY - currentY <= 2
            let atTop = currentY <= 2
            let contentCanScroll = documentHeight > visibleHeight + 2

            onBottomStateChange(atBottom)
            if userInitiated, contentCanScroll, atTop, !isAtTop {
                onTopReached()
            }
            isAtTop = atTop
        }

        func scrollToBottom(_ scrollView: NSScrollView, animated: Bool) {
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let targetY = max(0, documentHeight - scrollView.contentView.bounds.height)
            scroll(scrollView, toY: targetY, animated: animated)
        }

        func scroll(_ scrollView: NSScrollView, toY y: CGFloat, animated: Bool) {
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maxY = max(0, documentHeight - scrollView.contentView.bounds.height)
            let target = NSPoint(x: 0, y: min(max(0, y), maxY))
            isProgrammaticScroll = true
            if animated {
                scrollView.contentView.animator().setBoundsOrigin(target)
            } else {
                scrollView.contentView.setBoundsOrigin(target)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = false
            handleScroll(scrollView, userInitiated: false)
        }
    }
}

@MainActor
private final class NotifyingScrollView: NSScrollView {
    var onScroll: ((Bool) -> Void)?
    private var isHandlingUserScroll = false

    override func scrollWheel(with event: NSEvent) {
        isHandlingUserScroll = true
        super.scrollWheel(with: event)
        isHandlingUserScroll = false
        onScroll?(true)
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        onScroll?(isHandlingUserScroll)
    }
}
