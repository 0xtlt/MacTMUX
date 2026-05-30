import AppKit
import MacTMUXCore
import SwiftUI

struct SessionsWindowView: View {
    @EnvironmentObject private var store: MacTMUXStore
    @AppStorage("sessionsSidebarWidth") private var sidebarWidth = Double(SidebarWidth.defaultValue)
    @State private var selectedSessionIDs = Set<String>()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: effectiveSidebarWidth(for: geometry.size.width))

                    SidebarResizeHandle(
                        sidebarWidth: $sidebarWidth,
                        availableWidth: geometry.size.width
                    )

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
        .onChange(of: store.selectedSession?.id) { _, _ in
            syncSelectionWithFocusedSession()
        }
    }

    private func effectiveSidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        SidebarWidth.clamp(CGFloat(sidebarWidth), availableWidth: availableWidth)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.sessions) { session in
                        SessionRow(
                            session: session,
                            isSelected: selectedSessionIDs.contains(session.id),
                            onSelect: {
                                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                                    toggleSessionSelection(session)
                                } else {
                                    selectSession(session)
                                }
                            }
                        )
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 8)
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        await store.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .controlSize(.small)
                .labelStyle(.iconOnly)
                .help("Refresh sessions")

                Spacer()

                Text("\(store.sessions.count) sessions")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
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
    }

    private var selectedSessions: [TmuxSession] {
        store.sessions.filter { selectedSessionIDs.contains($0.id) }
    }

    private var sessionIDs: [String] {
        store.sessions.map(\.id)
    }

    private func selectSession(_ session: TmuxSession) {
        let previousSelection = selectedSessionIDs
        selectedSessionIDs = [session.id]
        focusSessionAfterSelectionChange(from: previousSelection, to: selectedSessionIDs)
    }

    private func toggleSessionSelection(_ session: TmuxSession) {
        let previousSelection = selectedSessionIDs
        if selectedSessionIDs.contains(session.id) {
            selectedSessionIDs.remove(session.id)
        } else {
            selectedSessionIDs.insert(session.id)
        }
        focusSessionAfterSelectionChange(from: previousSelection, to: selectedSessionIDs)
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
        if let selectedSession = store.selectedSession,
           selectedSessionIDs.count != 1 || !selectedSessionIDs.contains(selectedSession.id) {
            selectedSessionIDs = [selectedSession.id]
        }
        pruneSelectedSessionIDs()
    }

    private func pruneSelectedSessionIDs() {
        let previousSelection = selectedSessionIDs
        let focusedID = store.selectedSession?.id
        let validSessionIDs = Set(sessionIDs)
        selectedSessionIDs.formIntersection(validSessionIDs)

        guard selectedSessionIDs != previousSelection else {
            return
        }

        if selectedSessionIDs.isEmpty || focusedID.map({ !selectedSessionIDs.contains($0) }) == true {
            focusSessionAfterSelectionChange(from: previousSelection, to: selectedSessionIDs)
        }
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
    var isSelected = false
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
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
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            SessionLinksControl(
                links: store.recentLinks(for: session),
                isHighlighted: isSelected
            )
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
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

                SessionLinksControl(links: store.recentLinks(for: session))

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

            LogOutputView(session: session)
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
    @AppStorage("wrapsLongLogLines") private var wrapsLongLogLines = false

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
        .onChange(of: store.selectedPane?.id) { _, _ in
            didInitialBottomScroll = false
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
            paneSelector

            HStack(spacing: 8) {
                TextField("Search logs", text: $filterCriteria.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

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

    private var paneSelector: some View {
        let panes = store.panes(for: session)
        return HStack(spacing: 8) {
            if panes.count > 1 {
                Picker("Pane", selection: Binding(
                    get: { store.selectedPane?.id ?? "" },
                    set: { paneID in
                        guard let pane = panes.first(where: { $0.id == paneID }) else {
                            return
                        }
                        Task {
                            await store.selectPane(pane, for: session)
                        }
                    }
                )) {
                    ForEach(panes) { pane in
                        Text(panePickerTitle(for: pane))
                            .tag(pane.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)
            } else if let pane = panes.first {
                Label(panePickerTitle(for: pane), systemImage: "rectangle.split.1x2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        Text(emptyStateText)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyStateText: String {
        if store.logLines.isEmpty {
            if store.isLoadingSelectedInitialLogs {
                return "Loading logs..."
            }
            if let pane = store.selectedPane {
                return "No logs captured for \(pane.displayName) yet"
            }
            return "No panes found for this session"
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

    private func panePickerTitle(for pane: TmuxPane) -> String {
        if pane.currentCommand.isEmpty {
            return pane.displayName
        }
        return "\(pane.displayName) · \(pane.currentCommand)"
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

        let textView = LogTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = LogTextAttributedStringBuilder.logFont
        textView.linkTextAttributes = LogTextAttributedStringBuilder.linkTextAttributes
        textView.delegate = context.coordinator

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
            textView.textStorage?.setAttributedString(LogTextAttributedStringBuilder.attributedString(for: lines))
            (textView as? LogTextView)?.clearCommandLinkInteraction()
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
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
            super.init()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let event = NSApp.currentEvent,
                  LogTextAttributedStringBuilder.shouldOpenLink(modifierFlags: event.modifierFlags),
                  let url = LogTextAttributedStringBuilder.allowedLinkURL(from: link) else {
                return true
            }

            NSWorkspace.shared.open(url)
            return true
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
private final class LogTextView: NSTextView {
    private var mouseTrackingArea: NSTrackingArea?
    private var modifierMonitor: Any?
    private var highlightedLinkRange: NSRange?
    private var lastMouseLocation: NSPoint?
    private var isMouseInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            removeModifierMonitor()
            clearCommandLinkInteraction()
        } else {
            installModifierMonitorIfNeeded()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        updateCommandLinkInteraction(modifierFlags: event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        isMouseInside = true
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        updateCommandLinkInteraction(modifierFlags: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        lastMouseLocation = nil
        clearCommandLinkInteraction()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCommandLinkInteraction(modifierFlags: event.modifierFlags)
    }

    func clearCommandLinkInteraction() {
        updateHighlightedLinkRange(nil)
        NSCursor.iBeam.set()
    }

    private func installModifierMonitorIfNeeded() {
        guard modifierMonitor == nil else {
            return
        }

        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateCommandLinkInteraction(modifierFlags: event.modifierFlags)
            return event
        }
    }

    private func removeModifierMonitor() {
        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
        }
        modifierMonitor = nil
    }

    private func updateCommandLinkInteraction(modifierFlags: NSEvent.ModifierFlags) {
        guard isMouseInside,
              let lastMouseLocation,
              LogTextAttributedStringBuilder.shouldOpenLink(modifierFlags: modifierFlags),
              let linkRange = linkRange(at: lastMouseLocation) else {
            clearCommandLinkInteraction()
            return
        }

        updateHighlightedLinkRange(linkRange)
        NSCursor.openHand.set()
    }

    private func updateHighlightedLinkRange(_ range: NSRange?) {
        if highlightedLinkRange == range {
            return
        }

        if let highlightedLinkRange {
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: highlightedLinkRange)
            layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: highlightedLinkRange)
        }

        highlightedLinkRange = range

        if let range {
            layoutManager?.addTemporaryAttributes(
                LogTextAttributedStringBuilder.commandLinkHoverAttributes,
                forCharacterRange: range
            )
        }
    }

    private func linkRange(at point: NSPoint) -> NSRange? {
        guard let textContainer,
              let layoutManager,
              let textStorage,
              !string.isEmpty else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)

        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            return nil
        }

        let glyphRange = NSRange(location: glyphIndex, length: 1)
        let glyphBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard glyphBounds.insetBy(dx: -2, dy: -3).contains(containerPoint) else {
            return nil
        }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length else {
            return nil
        }

        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        guard textStorage.attribute(.link, at: characterIndex, effectiveRange: &effectiveRange) != nil,
              effectiveRange.location != NSNotFound else {
            return nil
        }

        return effectiveRange
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
