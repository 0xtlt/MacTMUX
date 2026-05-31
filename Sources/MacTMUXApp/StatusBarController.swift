import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: MacTMUXStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var sessionsCancellable: AnyCancellable?

    init(store: MacTMUXStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        super.init()

        configureStatusItem()
        configurePopover()
        observeSessions()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusIcon(sessionCount: store.sessions.count)
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

    private func observeSessions() {
        sessionsCancellable = store.$sessions
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] sessionCount in
                self?.updateStatusIcon(sessionCount: sessionCount)
            }
    }

    private func updateStatusIcon(sessionCount: Int) {
        guard let button = statusItem.button else {
            return
        }

        if sessionCount > 0 {
            button.image = makeBadgeImage(sessionCount: sessionCount)
        } else {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "MacTMUX")
            button.image?.isTemplate = true
        }

        button.toolTip = StatusBarBadgeFormatter.toolTip(sessionCount: sessionCount)
    }

    private func makeBadgeImage(sessionCount: Int) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size)
        image.lockFocus()
        defer {
            image.unlockFocus()
        }

        if let terminalImage = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
            NSColor.black.set()
            terminalImage.draw(
                in: NSRect(x: 0, y: 1, width: 15, height: 15),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        let badgeRect = NSRect(x: 10, y: 10, width: 10, height: 10)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let badgeText = StatusBarBadgeFormatter.badgeText(sessionCount: sessionCount)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: badgeText.count > 1 ? 5.2 : 6.8, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let textSize = badgeText.size(withAttributes: attributes)
        let textRect = NSRect(
            x: badgeRect.midX - (textSize.width / 2),
            y: badgeRect.midY - (textSize.height / 2) - 0.4,
            width: textSize.width,
            height: textSize.height
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        badgeText.draw(in: textRect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()

        image.isTemplate = true
        return image
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        Task {
            await store.refresh()
            await store.startLogRefreshLoop()
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

enum StatusBarBadgeFormatter {
    static func badgeText(sessionCount: Int) -> String {
        guard sessionCount > 9 else {
            return "\(max(0, sessionCount))"
        }
        return "9+"
    }

    static func toolTip(sessionCount: Int) -> String {
        guard sessionCount > 0 else {
            return "MacTMUX"
        }

        let noun = sessionCount == 1 ? "session" : "sessions"
        return "MacTMUX - \(sessionCount) tmux \(noun)"
    }
}
