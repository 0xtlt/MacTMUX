import MacTMUXCore
import SwiftUI

private enum LogScrollTarget {
    static let bottom = "log-bottom"
    static let topLoader = "log-top-loader"
}

struct LogOutputView: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession
    var filterCriteria: LogFilterCriteria
    var wrapsLongLogLines: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            paneSelector

            logSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayedLogLines: [LogLine] {
        filterCriteria.filter(store.logLines)
    }

    private var logSurface: some View {
        Group {
            if displayedLogLines.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeLogTextView(
                    lines: displayedLogLines,
                    wrapsLines: wrapsLongLogLines,
                    canLoadOlder: store.canLoadOlderLogs,
                    isLoadingOlder: store.isLoadingOlderLogs,
                    loadOlder: loadOlderIfNeeded
                )
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
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
                .frame(maxWidth: 340, alignment: .leading)
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

    private func loadOlderIfNeeded() {
        guard store.canLoadOlderLogs else {
            return
        }

        Task {
            await store.loadOlderLogs(for: session)
        }
    }

    private func panePickerTitle(for pane: TmuxPane) -> String {
        if pane.currentCommand.isEmpty {
            return pane.displayName
        }
        return "\(pane.displayName) · \(pane.currentCommand)"
    }
}

private struct NativeLogTextView: View {
    var lines: [LogLine]
    var wrapsLines: Bool
    var canLoadOlder: Bool
    var isLoadingOlder: Bool
    var loadOlder: () -> Void
    @State private var isReadyForOlderLoad = false
    @State private var isTopLoaderVisible = false
    @State private var prependAnchorLineID: LogLine.ID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(scrollAxes) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    olderLogLoader
                        .id(LogScrollTarget.topLoader)

                    ForEach(lines) { line in
                        LogLineText(line: line, wrapsLines: wrapsLines)
                            .id(line.id)
                    }

                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(LogScrollTarget.bottom)
                }
                .padding(12)
                .frame(maxWidth: wrapsLines ? .infinity : nil, alignment: .topLeading)
            }
            .textSelection(.enabled)
            .onAppear {
                scrollToBottom(proxy, animated: false)
                DispatchQueue.main.async {
                    isReadyForOlderLoad = true
                    loadOlderIfTopLoaderIsVisible()
                }
            }
            .onChange(of: lines.last?.id) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: lines.first?.id) { oldFirstID, newFirstID in
                guard oldFirstID != nil, oldFirstID != newFirstID, let prependAnchorLineID else {
                    return
                }
                proxy.scrollTo(prependAnchorLineID, anchor: .top)
                self.prependAnchorLineID = nil
            }
            .onChange(of: isLoadingOlder) { _, isLoading in
                if !isLoading {
                    loadOlderIfTopLoaderIsVisible()
                }
            }
        }
    }

    private var olderLogLoader: some View {
        Color.clear
            .frame(height: 1)
            .onAppear {
                isTopLoaderVisible = true
                loadOlderIfTopLoaderIsVisible()
            }
            .onDisappear {
                isTopLoaderVisible = false
            }
    }

    private var scrollAxes: Axis.Set {
        wrapsLines ? .vertical : [.horizontal, .vertical]
    }

    private func loadOlderIfTopLoaderIsVisible() {
        guard isReadyForOlderLoad, isTopLoaderVisible, canLoadOlder, !isLoadingOlder else {
            return
        }

        prependAnchorLineID = lines.first?.id
        loadOlder()
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(LogScrollTarget.bottom, anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                action()
            }
        } else {
            action()
        }
    }
}

private struct LogLineText: View {
    var line: LogLine
    var wrapsLines: Bool

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(line.level.displayColor)
            .lineLimit(wrapsLines ? nil : 1)
            .fixedSize(horizontal: !wrapsLines, vertical: true)
            .frame(maxWidth: wrapsLines ? .infinity : nil, alignment: .leading)
    }
}

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
