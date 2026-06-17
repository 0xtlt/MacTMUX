import MacTMUXCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: MacTMUXStore
    @AppStorage("showMenuBarSessionCount") private var showMenuBarSessionCount = true
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    var body: some View {
        TabView {
            Form {
                startupSection
                menuBarSection
                refreshSection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            Form {
                terminalSection
                tmuxSection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Terminal", systemImage: "terminal")
            }

            Form {
                logsSection
                safetySection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }
        }
        .frame(width: 520, height: 340)
        .scenePadding()
        .onAppear {
            launchAtLogin.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                launchAtLogin.refresh()
            }
        }
    }

    private var startupSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .disabled(launchAtLogin.isUnavailable)

            Text(launchAtLogin.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage = launchAtLogin.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if launchAtLogin.shouldShowLoginItemsButton {
                Button("Open Login Items Settings") {
                    launchAtLogin.openLoginItemsSettings()
                }
            }
        }
    }

    private var refreshSection: some View {
        Section("Refresh") {
            Stepper(value: $store.refreshInterval, in: 2...60, step: 1) {
                Text("Refresh interval: \(Int(store.refreshInterval))s")
            }

            Toggle("Show CPU and RAM", isOn: Binding(
                get: { store.showResourceMetrics },
                set: { store.showResourceMetrics = $0 }
            ))

            if let metricsErrorMessage = store.metricsErrorMessage {
                Text(metricsErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var menuBarSection: some View {
        Section("Menu bar") {
            Toggle("Show session count", isOn: $showMenuBarSessionCount)
        }
    }

    private var terminalSection: some View {
        Section("Default terminal") {
            Picker("Terminal", selection: Binding(
                get: { store.terminalKind },
                set: { store.terminalKind = $0 }
            )) {
                ForEach(TerminalKind.allCases) { terminal in
                    Text(terminalLabel(terminal))
                        .tag(terminal)
                }
            }
            .pickerStyle(.menu)

            Text(terminalHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tmuxSection: some View {
        Section("tmux") {
            TextField("Binary path", text: Binding(
                get: { store.tmuxPathSetting },
                set: { store.tmuxPathSetting = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Use Autodetect") {
                    store.resetTmuxPathToAutodetect()
                }

                Spacer()

                Text(store.tmuxPath ?? "Not found")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var logsSection: some View {
        Section("Logs") {
            Toggle("Auto-refresh selected logs", isOn: Binding(
                get: { store.autoRefreshLogs },
                set: { store.autoRefreshLogs = $0 }
            ))

            Text("Logs are displayed in memory. Common secrets are redacted before rendering.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var safetySection: some View {
        Section("Safety") {
            Toggle("Always confirm stop and restart", isOn: .constant(true))
                .disabled(true)

            Text("Session stop and restart actions stay explicit from the menu bar and the main window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func terminalLabel(_ terminal: TerminalKind) -> String {
        terminal.isInstalled ? terminal.displayName : "\(terminal.displayName) (not installed)"
    }

    private var terminalHelp: String {
        switch store.terminalKind {
        case .terminalApp:
            return "Uses Terminal.app AppleScript to open a new tmux attach command."
        case .iTerm2:
            return "Uses iTerm2 AppleScript. Install iTerm2 before selecting this."
        case .warp:
            return "Creates a MacTMUX launch configuration in ~/.warp/launch_configurations and opens it with Warp."
        case .ghostty:
            return "Uses Ghostty app arguments through macOS open."
        case .cmux:
            return "Uses cmux CLI new-workspace --command. cmux automation/socket access must allow MacTMUX."
        }
    }
}
