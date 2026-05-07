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
        .menuBarExtraStyle(.window)
    }
}
