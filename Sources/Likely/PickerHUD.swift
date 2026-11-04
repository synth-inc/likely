import AppKit
import ApplicationServices
import SwiftUI

/// What the HUD shows; the coordinator updates it as Claude works.
final class HUDModel: ObservableObject {
    @Published var status = "Looking at the context"
    @Published var working = true
    @Published var fileCount = 0
    @Published var draft = ""
    var onSend: ((String) -> Void)?
    var onRejectAll: (() -> Void)?
}

/// A slim floating bar glued above (or below) the open picker: live status from Claude plus a text
/// box to correct it. Lives in a non-activating panel so the picker's app stays frontmost.
final class PickerHUD {
    let model = HUDModel()

    private let panel: HUDPanel
    private var trackTimer: Timer?
    private var pickerElement: AXUIElement?
    private var fallbackFrame: CGRect?
    private var sidebar: AXUIElement?
    private var sidebarLookups = 0
    private static let height: CGFloat = 86
    private static let gap: CGFloat = 8

    init() {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: Self.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // Above modal open panels (which sit at the modal-panel level).
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: HUDView(model: model) { [weak self] in self?.returnFocusToPicker() })
    }

    func show(attachedTo element: AXUIElement?, fallbackFrame: CGRect?) {
        pickerElement = element
        self.fallbackFrame = fallbackFrame
        sidebar = nil
        sidebarLookups = 0
        model.status = "Looking at the context"
        model.working = true
        model.fileCount = 0
        model.draft = ""
        guard reposition() else { return }
        panel.orderFrontRegardless()
        trackTimer?.invalidate()
        trackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.reposition() }
    }

    func hide() {
        trackTimer?.invalidate()
        trackTimer = nil
        panel.orderOut(nil)
        pickerElement = nil
    }

    /// Follows the picker as it moves or resizes. AX frames are top-left-origin; AppKit's are bottom-left.
    @discardableResult
    private func reposition() -> Bool {
        guard let picker = pickerElement.flatMap(AX.frame) ?? fallbackFrame,
              let primary = NSScreen.screens.first else { return false }
        let flippedTop = primary.frame.maxY - picker.minY
        let flippedBottom = primary.frame.maxY - picker.maxY
        // Span from the sidebar's right edge to the picker's right edge, lining up with the file list.
        var left = picker.minX
        if let sidebarRight = sidebarRightEdge(), sidebarRight > picker.minX, picker.maxX - sidebarRight >= 360 {
            left = sidebarRight
        }
        let width = picker.maxX - left
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: picker.midX, y: flippedBottom + picker.height / 2)) } ?? primary
        let visible = screen.visibleFrame

        // Prefer just above the picker; if that runs off-screen, go below it; failing both, overlap its top edge.
        var y = flippedTop + Self.gap
        if y + Self.height > visible.maxY {
            y = flippedBottom - Self.gap - Self.height
            if y < visible.minY { y = flippedTop - Self.gap - Self.height }
        }
        let x = min(max(left, visible.minX), visible.maxX - width)
        let frame = NSRect(x: x, y: y, width: width, height: Self.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        return true
    }

    /// Right edge (AX coordinates) of the picker's sidebar. The sidebar is often populated a beat after
    /// the picker appears, so keep looking for a few seconds before settling for full width.
    private func sidebarRightEdge() -> CGFloat? {
        if sidebar == nil, let pickerElement, sidebarLookups < 30 {
            sidebarLookups += 1
            sidebar = PickerNavigator.findSidebar(in: pickerElement)
        }
        guard let sidebar else { return nil }
        // The outline's scroll area is the visible column (the outline itself can be wider when scrolled).
        let container = AX.element(sidebar, kAXParentAttribute).flatMap { AX.string($0, kAXRoleAttribute) == kAXScrollAreaRole ? $0 : nil }
        return (container.flatMap(AX.frame) ?? AX.frame(sidebar))?.maxX
    }

    /// Typing moved keyboard focus into our panel; hand it back so the picker reacts to keys again.
    private func returnFocusToPicker() {
        panel.makeFirstResponder(nil)
        guard let pickerElement else { return }
        AXUIElementPerformAction(pickerElement, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(pickerElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        if let app = NSRunningApplication(processIdentifier: AX.pid(pickerElement)) {
            app.activate()
        }
    }
}

/// Borderless panels refuse key status by default, which would make the text field untypeable.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    var returnFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.fileCount > 0 ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(model.fileCount > 0 ? Color.green : Color.secondary)
                }
                Text(model.status)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if model.fileCount > 0 {
                    Button("Not these") {
                        model.onRejectAll?()
                        returnFocus()
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                TextField("Tell Likely what you're looking for…", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 12)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
    }

    private func send() {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.draft = ""
        model.onSend?(text)
        returnFocus()
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
