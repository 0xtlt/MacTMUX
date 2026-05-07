import MacTMUXCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MacTMUXStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("MacTMUX")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "Terminal") {
                Picker("Default terminal", selection: Binding(
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

            SettingsSection(title: "tmux") {
                TextField("tmux binary path", text: Binding(
                    get: { store.tmuxPathSetting },
                    set: { store.tmuxPathSetting = $0 }
                ))
                .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Use autodetect") {
                        store.resetTmuxPathToAutodetect()
                    }

                    Spacer()

                    Text(store.tmuxPath ?? "Not found")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(title: "Refresh") {
                Stepper(value: $store.refreshInterval, in: 2...60, step: 1) {
                    Text("Refresh interval: \(Int(store.refreshInterval))s")
                }
            }

            SettingsSection(title: "Safety") {
                Toggle("Always confirm stop and restart", isOn: .constant(true))
                    .disabled(true)

                Text("Logs are displayed in memory only and common secrets are redacted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
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

private struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.07))
            )
        }
    }

}
