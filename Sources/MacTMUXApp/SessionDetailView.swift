import MacTMUXCore
import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession
    var selectedSessions: [TmuxSession]
    var requestRestart: (TmuxSession) -> Void
    var requestStop: (TmuxSession) -> Void
    var requestStopSelectedSessions: () -> Void

    @State private var filterCriteria = LogFilterCriteria()
    @State private var isLogOptionsPresented = false
    @State private var isManualReloadingLogs = false
    @AppStorage("sessionOutputMode") private var outputModeRaw = SessionOutputMode.terminal.rawValue
    @AppStorage("wrapsLongLogLines") private var wrapsLongLogLines = false

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader

            Divider()

            outputSurface
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                displayModePicker
            }

            if outputMode == .logs {
                ToolbarItemGroup(placement: .primaryAction) {
                    logOptionsButton
                    reloadLogsButton
                }
            }
        }
        .modifier(LogSearchToolbarModifier(
            isEnabled: outputMode == .logs,
            query: $filterCriteria.query
        ))
        .onAppear {
            refreshVisibleLogsIfNeeded()
        }
        .onChange(of: session.id) { _, _ in
            filterCriteria = LogFilterCriteria()
            refreshVisibleLogsIfNeeded()
        }
        .onChange(of: outputMode) { _, _ in
            refreshVisibleLogsIfNeeded()
        }
    }

    @ViewBuilder
    private var outputSurface: some View {
        switch outputMode {
        case .terminal:
            IntegratedTerminalView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .logs:
            LogOutputView(
                session: session,
                filterCriteria: filterCriteria,
                wrapsLongLogLines: wrapsLongLogLines
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var outputMode: SessionOutputMode {
        get {
            SessionOutputMode(rawValue: outputModeRaw) ?? .terminal
        }
        nonmutating set {
            outputModeRaw = newValue.rawValue
        }
    }

    private var outputModeBinding: Binding<SessionOutputMode> {
        Binding(
            get: { outputMode },
            set: { outputMode = $0 }
        )
    }

    private var displayModePicker: some View {
        Picker(selection: outputModeBinding) {
            ForEach(SessionOutputMode.allCases) { mode in
                Text(mode.toolbarTitle)
                    .tag(mode)
            }
        } label: { Text("Display Mode") }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 128)
        .help("Switch between interactive CLI and captured logs")
        .accessibilityLabel("Display mode")
        .accessibilityValue(outputMode.menuTitle)
    }

    private var logOptionsButton: some View {
        Button {
            isLogOptionsPresented.toggle()
        } label: {
            ToolbarCommandLabel(
                title: "Options",
                systemImage: "slider.horizontal.3"
            )
        }
        .controlSize(.small)
        .help("Log filtering and display options")
        .accessibilityLabel("Log options")
        .popover(isPresented: $isLogOptionsPresented, arrowEdge: .bottom) {
            LogOptionsPopover(
                enabledLevels: $filterCriteria.enabledLevels,
                autoRefreshLogs: Binding(
                    get: { store.autoRefreshLogs },
                    set: { store.autoRefreshLogs = $0 }
                ),
                wrapsLongLogLines: $wrapsLongLogLines
            )
        }
    }

    private var reloadLogsButton: some View {
        Button {
            reloadLogsManually()
        } label: {
            ToolbarCommandLabel(title: "Reload", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
        .disabled(isManualReloadingLogs)
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
        .help("Reload logs")
        .accessibilityLabel("Reload logs")
    }

    private func reloadLogsManually() {
        guard !isManualReloadingLogs else {
            return
        }

        isManualReloadingLogs = true
        Task { @MainActor in
            await store.refreshLatestLogs(for: session)
            isManualReloadingLogs = false
        }
    }

    private func refreshVisibleLogsIfNeeded() {
        guard outputMode == .logs else {
            return
        }

        Task {
            await store.refreshLatestLogs(for: session)
        }
    }

    private var sessionHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: 14) {
                    Label(sessionStatusText, systemImage: "rectangle.on.rectangle")
                        .foregroundStyle(.secondary)

                    if let metricsText = store.metricsText(for: session) {
                        Label(metricsText, systemImage: "gauge.with.dots.needle.33percent")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            if selectedSessions.count > 1 {
                Text("\(selectedSessions.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: Capsule())
                    .fixedSize()
            }

            sessionActions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var sessionActions: some View {
        HStack(spacing: 8) {
            SessionLinksControl(links: store.recentLinks(for: session))

            Button {
                Task {
                    await store.open(session)
                }
            } label: {
                Label("Open", systemImage: "terminal")
            }
            .help("Open session")

            Button {
                requestRestart(session)
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .help("Restart active pane")

            if selectedSessions.count > 1 {
                Button {
                    requestStopSelectedSessions()
                } label: {
                    Label("Stop \(selectedSessions.count)", systemImage: "power")
                }
                .tint(.red)
                .help("Stop selected sessions")
            } else {
                Button {
                    requestStop(session)
                } label: {
                    Label("Stop", systemImage: "power")
                }
                .tint(.red)
                .help("Stop session")
            }
        }
        .controlSize(.regular)
        .buttonStyle(.glass)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sessionStatusText: String {
        "\(session.windows) \(session.windows == 1 ? "window" : "windows")"
    }
}

private enum SessionOutputMode: String, CaseIterable, Identifiable {
    case terminal
    case logs

    var id: String {
        rawValue
    }

    var toolbarTitle: String {
        switch self {
        case .terminal:
            return "CLI"
        case .logs:
            return "Logs"
        }
    }

    var menuTitle: String {
        switch self {
        case .terminal:
            return "Interactive CLI"
        case .logs:
            return "Captured Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal:
            return "terminal"
        case .logs:
            return "doc.text"
        }
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

private struct LogOptionsPopover: View {
    @Binding var enabledLevels: Set<LogLevel>
    @Binding var autoRefreshLogs: Bool
    @Binding var wrapsLongLogLines: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Level Filters")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(logLevelFilterItems, id: \.level) { item in
                        Toggle(item.title, isOn: levelBinding(for: item.level))
                            .toggleStyle(.checkbox)
                    }
                }

                Button("Show All Levels") {
                    enabledLevels = LogLevel.allCasesSet
                }
                .disabled(enabledLevels == LogLevel.allCasesSet)
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Display")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Toggle("Auto Refresh", isOn: $autoRefreshLogs)
                    .toggleStyle(.checkbox)

                Toggle("Wrap Lines", isOn: $wrapsLongLogLines)
                    .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func levelBinding(for level: LogLevel) -> Binding<Bool> {
        Binding(
            get: { enabledLevels.contains(level) },
            set: { isEnabled in
                if isEnabled {
                    enabledLevels.insert(level)
                } else {
                    enabledLevels.remove(level)
                }
            }
        )
    }
}

private struct ToolbarCommandLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
            Text(title)
                .font(.callout)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct LogSearchToolbarModifier: ViewModifier {
    var isEnabled: Bool
    @Binding var query: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $query, placement: .toolbar, prompt: "Search logs")
        } else {
            content
        }
    }
}
