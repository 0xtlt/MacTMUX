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
    @AppStorage("sessionOutputMode") private var outputModeRaw = SessionOutputMode.logs.rawValue
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
                HStack(spacing: 8) {
                    if IntegratedTerminalFeature.isEnabled {
                        Picker("Output mode", selection: outputModeBinding) {
                            ForEach(SessionOutputMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.systemImage)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 160)
                        .help("Switch between captured logs and experimental terminal")
                    }

                    if outputMode == .logs {
                        Button {
                            isLogOptionsPresented.toggle()
                        } label: {
                            ToolbarCommandLabel(
                                title: "Log Options",
                                systemImage: "slider.horizontal.3"
                            )
                        }
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

                        Button {
                            Task {
                                await store.refreshLatestLogs(for: session)
                            }
                        } label: {
                            ToolbarCommandLabel(title: "Reload", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isLoadingLogs)
                        .help("Reload logs")
                        .accessibilityLabel("Reload logs")
                    }
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .searchable(text: $filterCriteria.query, placement: .toolbar, prompt: "Search logs")
        .onChange(of: session.id) { _, _ in
            filterCriteria = LogFilterCriteria()
        }
    }

    @ViewBuilder
    private var outputSurface: some View {
        if outputMode == .terminal, IntegratedTerminalFeature.isEnabled {
            IntegratedTerminalView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogOutputView(
                session: session,
                filterCriteria: filterCriteria,
                wrapsLongLogLines: wrapsLongLogLines
            )
        }
    }

    private var outputMode: SessionOutputMode {
        get {
            SessionOutputMode(rawValue: outputModeRaw) ?? .logs
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

    private func levelBinding(for level: LogLevel) -> Binding<Bool> {
        Binding(
            get: { filterCriteria.enabledLevels.contains(level) },
            set: { isEnabled in
                if isEnabled {
                    filterCriteria.enabledLevels.insert(level)
                } else {
                    filterCriteria.enabledLevels.remove(level)
                }
            }
        )
    }
}

private enum SessionOutputMode: String, CaseIterable, Identifiable {
    case logs
    case terminal

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .logs:
            return "Logs"
        case .terminal:
            return "Terminal"
        }
    }

    var systemImage: String {
        switch self {
        case .logs:
            return "doc.text"
        case .terminal:
            return "terminal"
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
