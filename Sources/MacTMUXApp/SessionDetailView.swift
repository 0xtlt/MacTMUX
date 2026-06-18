import MacTMUXCore
import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession
    var selectedSessions: [TmuxSession]
    var requestRestart: (TmuxSession) -> Void
    var requestStop: (TmuxSession) -> Void
    var requestStopSelectedSessions: () -> Void

    @State private var terminalSearchQuery = ""
    @State private var terminalEnabledLevels = LogLevel.allCasesSet
    @State private var isLevelFilterPresented = false

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
                Button {
                    isLevelFilterPresented.toggle()
                } label: {
                    Label("Levels", systemImage: levelFilterSystemImage)
                }
                .controlSize(.small)
                .help("Filter terminal output by log level")
                .popover(isPresented: $isLevelFilterPresented, arrowEdge: .bottom) {
                    TerminalLevelFilterPopover(
                        enabledLevels: $terminalEnabledLevels
                    )
                }
            }
        }
        .searchable(text: $terminalSearchQuery, placement: .toolbar, prompt: "Search terminal")
        .onChange(of: session.id) { _, _ in
            terminalSearchQuery = ""
            terminalEnabledLevels = LogLevel.allCasesSet
        }
    }

    private var outputSurface: some View {
        IntegratedTerminalView(
            session: session,
            searchQuery: terminalSearchQuery,
            enabledLogLevels: terminalEnabledLevels
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var levelFilterSystemImage: String {
        terminalEnabledLevels == LogLevel.allCasesSet
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
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

private let terminalLogLevelFilterItems: [(level: LogLevel, title: String)] = [
    (.error, "Error"),
    (.warning, "Warn"),
    (.success, "Success"),
    (.info, "Info"),
    (.debug, "Debug"),
    (.plain, "Plain")
]

private struct TerminalLevelFilterPopover: View {
    @Binding var enabledLevels: Set<LogLevel>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Log Levels")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(terminalLogLevelFilterItems, id: \.level) { item in
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
