import AppKit
import MacTMUXCore
import SwiftUI

@main
struct MacTMUXApp: App {
    @StateObject private var store = MacTMUXStore()

    var body: some Scene {
        MenuBarExtra("MacTMUX", systemImage: "terminal") {
            MenuBarContentView()
                .environmentObject(store)
                .task {
                    await store.refresh()
                    await store.startRefreshLoop()
                }
        }
        .menuBarExtraStyle(.menu)

        Window("MacTMUX Sessions", id: "sessions") {
            SessionsWindowView()
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 480)
                .task {
                    await store.refresh()
                }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
