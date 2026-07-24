import AppKit
import SwiftUI

final class PanelWindowManager {
    static let shared = PanelWindowManager()
    static let defaultCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary
    ]
    static let panelStyleMask: NSWindow.StyleMask = [
        .titled,
        .fullSizeContentView
    ]
    static let titlebarSeparatorStyle: NSTitlebarSeparatorStyle = .none

    private weak var window: NSWindow?
    private var resizeObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var desiredVisible = false
    private var isRepositioning = false

    private init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.repositionToFocusedScreen(animated: false)
        }
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    func attach(window: NSWindow?) {
        guard let window else { return }
        if self.window !== window {
            self.window = window
            configure(window: window)
            observeResize(for: window)
        }
        repositionToFocusedScreen(animated: false)
        applyVisibility()
    }

    var currentWindow: NSWindow? {
        window
    }

    func repositionToFocusedScreen(animated: Bool = true) {
        guard let window else { return }
        guard let targetScreen = focusedScreen() else { return }
        if isRepositioning { return }
        isRepositioning = true
        defer { isRepositioning = false }

        let horizontalMargin: CGFloat = 0
        let bottomMargin: CGFloat = 0
        var newFrame = window.frame
        let maxWidth = targetScreen.visibleFrame.width - horizontalMargin * 2
        newFrame.size.width = maxWidth
        let maxHeight = max(200, targetScreen.visibleFrame.height - bottomMargin * 2)
        newFrame.size.height = min(newFrame.size.height, maxHeight)
        newFrame.origin.x = targetScreen.visibleFrame.minX + horizontalMargin
        newFrame.origin.y = targetScreen.visibleFrame.minY + bottomMargin

        if animated {
            window.animator().setFrame(newFrame, display: true)
        } else {
            window.setFrame(newFrame, display: true)
        }
        applyVisibility()
    }

    func setVisibility(_ visible: Bool) {
        desiredVisible = visible
        applyVisibility()
    }

    // MARK: - Private Helpers

    private func configure(window: NSWindow) {
        window.styleMask = Self.panelStyleMask
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = Self.titlebarSeparatorStyle
        window.toolbar = nil
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = Self.defaultCollectionBehavior
        window.level = .floating
        window.isReleasedWhenClosed = false
    }

    private func applyVisibility() {
        guard let window else { return }
        if desiredVisible {
            if NSApp.isHidden {
                NSApp.unhide(nil)
            }
            window.alphaValue = 1
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKey()
        } else {
            window.orderOut(nil)
            NSApp.hide(nil)
        }
    }

    private func focusedScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }
        if let activeWindow = NSApp.keyWindow,
           activeWindow !== window,
           let screen = activeWindow.screen {
            return screen
        }
        if let main = NSScreen.main {
            return main
        }
        return window?.screen ?? NSScreen.screens.first
    }

    private func observeResize(for window: NSWindow) {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isRepositioning { return }
            self.repositionToFocusedScreen(animated: false)
        }
    }
}

struct PanelWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            PanelWindowManager.shared.attach(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            PanelWindowManager.shared.attach(window: nsView.window)
        }
    }
}
