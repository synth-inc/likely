//
//  CornerToast.swift
//  OnboardingKit (adapted from Onit / Cloudless Voice's Hint pop-up messages and ToastPanelController)
//

import AppKit
import SwiftUI

/// A small floating message at the right edge of the screen ("Likely is running", …) that never takes
/// focus: a borderless non-activating panel above normal windows, on every Space. It slides in from
/// the right while fading in, dismisses itself after `duration` (a draining bar along its bottom shows
/// how long is left), and goes away on click. With Reduce Motion on it only fades.
///
/// Matches Cloudless's Hint pop-ups: HUD blur under a 65% white/black tint, 16pt corners, a 1pt T4
/// outline, centered icon / 15pt title / 13pt message, a close button in the top-right corner, and a
/// 0.15s ease-out slide of 8pt.
@MainActor
public final class CornerToast {
    public static let shared = CornerToast()

    /// Where on the screen's visible frame (below the menu bar, beside the Dock) the toast sits.
    public enum Anchor {
        /// Right edge, vertically centered: where Cloudless's pop-ups appear by default (next to its
        /// Hint, which is pinned to the right edge at mid-height).
        case rightCenter
        case topRight
        case bottomRight
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private let animationDuration: TimeInterval = 0.15
    private let slideOffset: CGFloat = 8
    private let edgeInset: CGFloat = 16

    private init() {}

    public var isVisible: Bool { panel != nil }

    /// Shows the toast, replacing any one already showing.
    /// - Parameters:
    ///   - icon: shown 32pt above the title (e.g. the app icon); nil for none.
    ///   - duration: seconds before it dismisses itself; nil keeps it until clicked.
    ///   - screen: defaults to the screen with the key window (else the main screen).
    public func show(title: String, message: String, icon: NSImage? = nil, duration: TimeInterval? = 6,
                     anchor: Anchor = .rightCenter, screen: NSScreen? = nil) {
        tearDown()
        guard let screen = screen ?? NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let view = CornerToastView(title: title, message: message, icon: icon, duration: duration) { [weak self] in
            self?.hide()
        }
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let toast = ToastPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = false
        toast.level = .floating
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        toast.hidesOnDeactivate = false
        toast.isReleasedWhenClosed = false
        toast.worksWhenModal = true
        toast.contentView = host

        let final = NSRect(origin: Self.origin(for: size, anchor: anchor, in: screen.visibleFrame, inset: edgeInset),
                           size: size)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        toast.setFrame(reduceMotion ? final : final.offsetBy(dx: slideOffset, dy: 0), display: true)
        toast.alphaValue = 0
        toast.orderFrontRegardless()   // never makes Likely active or the panel key
        panel = toast

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toast.animator().alphaValue = 1
            if !reduceMotion { toast.animator().setFrame(final, display: true) }
        }

        if let duration {
            hideTask = Task { @MainActor [weak self, weak toast] in
                try? await Task.sleep(for: .seconds(duration))
                // A newer toast replaced this one: leave it (and its own timer) alone.
                guard !Task.isCancelled, let self, let toast, self.panel === toast else { return }
                self.hide()
            }
        }
    }

    /// Fades (and, without Reduce Motion, slides) the toast back out.
    public func hide() {
        guard let leaving = panel else { return }
        hideTask?.cancel()
        hideTask = nil
        panel = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            leaving.animator().alphaValue = 0
            if !reduceMotion { leaving.animator().setFrame(leaving.frame.offsetBy(dx: slideOffset, dy: 0), display: true) }
        }, completionHandler: {
            leaving.orderOut(nil)
            leaving.contentView = nil
        })
    }

    private func tearDown() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Bottom-left origin (AppKit coordinates) for a toast of `size` at `anchor`.
    nonisolated static func origin(for size: CGSize, anchor: Anchor, in visible: CGRect, inset: CGFloat) -> CGPoint {
        let x = max(visible.minX, visible.maxX - size.width - inset)
        switch anchor {
        case .rightCenter: return CGPoint(x: x, y: visible.midY - size.height / 2)
        case .topRight: return CGPoint(x: x, y: visible.maxY - size.height - inset)
        case .bottomRight: return CGPoint(x: x, y: visible.minY + inset)
        }
    }
}

/// Never key or main, so clicks on the toast don't take focus from the app the user is in.
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

/// The toast's content. Public so an app can preview or snapshot it; `CornerToast` hosts it.
public struct CornerToastView: View {
    let title: String
    let message: String
    let icon: NSImage?
    let duration: TimeInterval?
    let opaqueBackdrop: Bool
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var closeHovered = false

    /// - Parameter opaqueBackdrop: a solid fill instead of the HUD blur (which only renders in a live
    ///   window), for snapshots.
    public init(title: String, message: String, icon: NSImage? = nil, duration: TimeInterval? = nil,
                opaqueBackdrop: Bool = false, onDismiss: @escaping () -> Void = {}) {
        self.title = title
        self.message = message
        self.icon = icon
        self.duration = duration
        self.opaqueBackdrop = opaqueBackdrop
        self.onDismiss = onDismiss
    }

    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    public var body: some View {
        VStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.onboardingS0)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.toastSecondaryText)
            }
            .multilineTextAlignment(.center)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 28)
        .background(Color.toastTint.opacity(0.65))
        .background {
            if opaqueBackdrop { Color.onboardingSmoke } else { VisualEffectView(material: .hudWindow) }
        }
        .overlay(alignment: .bottom) {
            // A draining bar is motion too: Reduce Motion drops it (the timer still runs).
            if let duration, !reduceMotion { TimerBar(duration: duration) }
        }
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(Color.onboardingDivider, lineWidth: 1))
        .fixedSize()
        .overlay(alignment: .topTrailing) { closeButton }
        .contentShape(Self.shape)
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismisses this message")
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(closeHovered ? Color.onboardingS0 : Color.toastTertiaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .onHover { closeHovered = $0 }
        .accessibilityLabel("Close")
    }

    /// Cloudless's AutoDismissTimerBar: a 2pt bar along the bottom that drains left over `duration`.
    private struct TimerBar: View {
        let duration: TimeInterval
        @State private var progress: CGFloat = 1

        var body: some View {
            GeometryReader { geometry in
                LinearGradient(stops: [.init(color: .toastTimer, location: 0),
                                       .init(color: .toastTimer, location: 0.85),
                                       .init(color: .toastTimer.opacity(0), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width * progress, height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2)
            .onAppear { withAnimation(.linear(duration: duration)) { progress = 0 } }
        }
    }
}

private extension Color {
    // Onit's asset-catalog colors (light / dark), as Cloudless's pop-ups use them.
    /// "S10": white / black, laid over the blur at 65%.
    static let toastTint = Color(NSColor(name: nil) { $0.isDark ? .black : .white })
    /// "T1": the message line.
    static let toastSecondaryText = dynamic(light: (0x43, 0x47, 0x52, 0.8), dark: (0xF1, 0xF5, 0xFF, 0.8))
    /// "T3": the close button at rest.
    static let toastTertiaryText = dynamic(light: (0x51, 0x58, 0x6A, 0.65), dark: (0xEA, 0xF0, 0xFF, 0.5))
    /// Cloudless draws the bar white (its pop-ups are usually dark); here it follows the appearance.
    static let toastTimer = Color(NSColor(name: nil) { $0.isDark ? .white : NSColor.black.withAlphaComponent(0.55) })

    static func dynamic(light: (Int, Int, Int, CGFloat), dark: (Int, Int, Int, CGFloat)) -> Color {
        Color(NSColor(name: nil) { appearance in
            let c = appearance.isDark ? dark : light
            return NSColor(displayP3Red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: c.3)
        })
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
