//
//  OnboardingWindowManager.swift
//  OnboardingKit (from DockLock, window setup matching Onit's CenteredWindow / OnboardingWindow)
//

import AppKit
import SwiftUI

/// Hosts an app's onboarding flow in the Onit-style 858×506 window: HUD blur ("brushed glass")
/// under the whole window, content extending under the transparent title bar, rounded 22pt corners.
@MainActor
public final class OnboardingWindowManager: NSObject, NSWindowDelegate {
    public static let shared = OnboardingWindowManager()
    public static let size = NSSize(width: 858, height: 506)

    private var window: NSWindow?
    private var onClose: (() -> Void)?

    public var isVisible: Bool { window?.isVisible ?? false }

    /// `onClose` runs however the window goes away (finished or closed with the close button).
    public func showWindow<Content: View>(_ content: Content, onClose: (() -> Void)? = nil) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        self.onClose = onClose

        let root = content
            .frame(width: Self.size.width, height: Self.size.height)
            .background(VisualEffectView(material: .hudWindow))
            .cornerRadius(22)
            .overlay(alignment: .top) { CopyEditorOverlay() }
            .ignoresSafeArea(.container, edges: .top)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.isRestorable = false
        win.contentView = FirstClickHostingView(rootView: root)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        Self.offsetTitlebarButtons(of: win, x: 10, y: 4)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    public func closeWindow() {
        window?.close()
        window = nil
    }

    /// Nudges the traffic lights inward to sit nicely inside the 22pt rounded corner (as Onit does).
    private static func offsetTitlebarButtons(of window: NSWindow, x: CGFloat, y: CGFloat) {
        guard let close = window.standardWindowButton(.closeButton),
              let minimize = window.standardWindowButton(.miniaturizeButton),
              let container = close.superview else { return }
        container.layoutSubtreeIfNeeded()
        for button in [close, minimize] {
            var origin = button.frame.origin
            origin.x += x
            origin.y -= y
            button.setFrameOrigin(origin)
        }
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        window = nil
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}

/// Accepts the first click without the window having to be activated first.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the copy-editing toolbar only while editing is on.
private struct CopyEditorOverlay: View {
    @ObservedObject var editor = CopyEditor.shared

    var body: some View {
        if editor.isEnabled { CopyEditorToolbar() }
    }
}
