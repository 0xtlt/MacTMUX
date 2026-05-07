import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: MacTMUXStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(store: MacTMUXStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        super.init()

        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "MacTMUX")
        button.imagePosition = .imageOnly
        button.toolTip = "MacTMUX"
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 300)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView()
                .environmentObject(store)
        )
        popover.delegate = self
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        Task {
            await store.refresh()
        }

        popover.contentSize = NSSize(width: 380, height: panelHeight())
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func panelHeight() -> CGFloat {
        if store.sessions.isEmpty {
            return 260
        }

        let rowCount = min(5, max(1, store.compactSessions.count))
        let rowsHeight = CGFloat(rowCount * 58)
        let rowSpacing = CGFloat(max(0, rowCount - 1) * 8)
        return min(460, max(260, 126 + rowsHeight + rowSpacing))
    }
}
