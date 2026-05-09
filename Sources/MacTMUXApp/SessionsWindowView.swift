import MacTMUXCore
import SwiftUI

struct SessionsWindowView: View {
    @EnvironmentObject private var store: MacTMUXStore
    @State private var isSidebarVisible = true
    @State private var selectedSessionIDs = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            HStack(spacing: 0) {
                if isSidebarVisible {
                    sidebar
                        .frame(width: 280)

                    Divider()
                }

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08))
            )
            .help(isSidebarVisible ? "Hide sidebar" : "Show sidebar")

            Text("MacTMUX Sessions")
                .font(.headline)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
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

private struct LogOutputView: View {
    @EnvironmentObject private var store: MacTMUXStore
    var session: TmuxSession

    @State private var isAtBottom = true
    @State private var pendingTopAnchorID: String?
    @State private var didInitialBottomScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    topSentinel(proxy: proxy)

                    if store.logLines.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.logLines) { line in
                            LogLineView(line: line)
                                .id(line.id)
                        }
                    }

                    bottomSentinel
                }
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                didInitialBottomScroll = false
                scrollToBottomAfterLayout(proxy: proxy)
            }
            .onChange(of: store.logRevision) { _, _ in
                handleLogRevisionChange(proxy: proxy)
            }
            .onChange(of: session.id) { _, _ in
                didInitialBottomScroll = false
                scrollToBottomAfterLayout(proxy: proxy)
            }
        }
    }

    private func topSentinel(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 6) {
            Color.clear
                .frame(height: 1)
                .id(LogScrollTarget.top)
                .onAppear {
                    loadOlderIfNeeded(proxy: proxy)
                }

            if store.isLoadingOlderLogs {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    private var bottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(LogScrollTarget.bottom)
            .onAppear {
                isAtBottom = true
            }
            .onDisappear {
                isAtBottom = false
            }
    }

    private var emptyState: some View {
        Text(store.isLoadingInitialLogs ? "Loading logs..." : "No logs captured yet")
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
    }

    private func loadOlderIfNeeded(proxy: ScrollViewProxy) {
        guard store.canLoadOlderLogs,
              let anchorID = store.logLines.first?.id else {
            return
        }

        pendingTopAnchorID = anchorID
        Task {
            await store.loadOlderLogs(for: session)
            await MainActor.run {
                if pendingTopAnchorID == anchorID {
                    proxy.scrollTo(anchorID, anchor: .top)
                    pendingTopAnchorID = nil
                }
            }
        }
    }

    private func handleLogRevisionChange(proxy: ScrollViewProxy) {
        if let pendingTopAnchorID {
            proxy.scrollTo(pendingTopAnchorID, anchor: .top)
            self.pendingTopAnchorID = nil
            return
        }

        if !didInitialBottomScroll {
            scrollToBottomAfterLayout(proxy: proxy)
            return
        }

        if isAtBottom {
            scrollToBottom(proxy: proxy, animated: true)
        }
    }

    private func scrollToBottomAfterLayout(proxy: ScrollViewProxy) {
        Task {
            await Task.yield()
            await MainActor.run {
                scrollToBottom(proxy: proxy, animated: false)
                didInitialBottomScroll = true
                isAtBottom = true
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(LogScrollTarget.bottom, anchor: .bottom)
        }

        if animated {
            withAnimation(.linear(duration: 0.12), action)
        } else {
            action()
        }
    }
}

private struct LogLineView: View {
    var line: LogLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(line.level.displayColor)
            .frame(maxWidth: .infinity, alignment: .leading)
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
