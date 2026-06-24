import AppKit
import SwiftUI

struct MenuPopoverFocusObserver: NSViewRepresentable {
    var onResignKey: () -> Void

    func makeNSView(context: Context) -> FocusObserverView {
        let view = FocusObserverView()
        view.onResignKey = onResignKey
        return view
    }

    func updateNSView(_ nsView: FocusObserverView, context: Context) {
        nsView.onResignKey = onResignKey
        nsView.attachToCurrentWindow()
    }
}

final class FocusObserverView: NSView {
    var onResignKey: (() -> Void)?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToCurrentWindow()
    }

    func attachToCurrentWindow() {
        guard observedWindow !== window else {
            return
        }

        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: observedWindow
            )
        }
        observedWindow = window

        guard let window else {
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window,
        )
    }

    @objc private func windowDidResignKey() {
        onResignKey?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
