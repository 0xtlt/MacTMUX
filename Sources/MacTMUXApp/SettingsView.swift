import MacTMUXCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MacTMUXStore

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Default terminal", selection: .constant("Terminal.app")) {
                    Text("Terminal.app").tag("Terminal.app")
                }
                .disabled(true)

                Text("iTerm2 and Warp adapters are reserved for a later version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("tmux") {
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

            Section("Refresh") {
                Stepper(value: $store.refreshInterval, in: 2...60, step: 1) {
                    Text("Refresh interval: \(Int(store.refreshInterval))s")
                }
            }

            Section("Safety") {
                Toggle("Always confirm stop and restart", isOn: .constant(true))
                    .disabled(true)

                Text("Logs are displayed in memory only and common secrets are redacted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
    }
}
