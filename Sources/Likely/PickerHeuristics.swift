import ApplicationServices
import Foundation

/// Decides whether an AX window/sheet is an open-file picker (NSOpenPanel or a lookalike).
enum PickerHeuristics {
    struct Verdict: CustomStringConvertible {
        let isPicker: Bool
        let reason: String
        var buttonTitle: String?
        var description: String { "\(isPicker ? "PICKER" : "no"): \(reason)" }
    }

    /// Guesses at a private attribute exposing the AppKit class name (Accessibility Inspector shows
    /// "[NSOpenPanel]"). None returned anything on macOS 26; still logged in diagnostics.
    static let classNameAttributes = ["AXClassName", "AXClass", "_AXClassName", "AXObjCClassName"]

    static let openPanelIdentifiers: Set<String> = ["open-panel", "OpenPanel"]

    static let openButtonTitles: Set<String> = [
        "open", "choose", "choose file", "choose files", "upload", "select", "attach", "insert", "import", "add",
    ]
    static let browserRoles: Set<String> = ["AXOutline", "AXBrowser", "AXTable", "AXList"]

    static func evaluate(_ window: AXUIElement) -> Verdict {
        let role = AX.string(window, kAXRoleAttribute)
        guard role == kAXWindowRole || role == kAXSheetRole else {
            return Verdict(isPicker: false, reason: "role \(role ?? "nil")")
        }

        // NSOpenPanel windows carry a stable AXIdentifier: "open-panel" on the app's own window,
        // "OpenPanel" on the system dialog that sandboxed apps get from the panel service.
        if let identifier = AX.string(window, kAXIdentifierAttribute) {
            if openPanelIdentifiers.contains(identifier) {
                return Verdict(isPicker: true, reason: "identifier=\(identifier)", buttonTitle: defaultButtonTitle(window))
            }
            if identifier.localizedCaseInsensitiveContains("savepanel") || identifier == "save-panel" {
                return Verdict(isPicker: false, reason: "identifier=\(identifier)")
            }
        }

        // Cheap gate: open panels have a default ("Open") and/or cancel button. Ordinary windows don't.
        let defaultTitle = defaultButtonTitle(window)
        let hasCancel = AX.element(window, kAXCancelButtonAttribute) != nil
        let title = AX.string(window, kAXTitleAttribute)?.lowercased() ?? ""
        guard defaultTitle != nil || hasCancel || openButtonTitles.contains(title) else {
            return Verdict(isPicker: false, reason: "no default/cancel button")
        }

        // Walk the subtree for an Open-ish button, a Cancel button and a file browser.
        var buttons = Set<String>()
        var roles = Set<String>()
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let elementRole = AX.string(element, kAXRoleAttribute) ?? ""
            roles.insert(elementRole)
            if elementRole == kAXButtonRole, let t = AX.string(element, kAXTitleAttribute) {
                buttons.insert(t.lowercased())
            }
            if buttons.contains("save") { return Verdict(isPicker: false, reason: "save panel") }
            if depth < 7 {
                queue.append(contentsOf: AX.elements(element, kAXChildrenAttribute).map { ($0, depth + 1) })
            }
        }

        let openTitle = defaultTitle.flatMap { openButtonTitles.contains($0.lowercased()) ? $0 : nil }
            ?? buttons.first(where: openButtonTitles.contains)
        let cancel = hasCancel || buttons.contains("cancel")
        let browser = !roles.isDisjoint(with: browserRoles)
        let summary = "default=\(defaultTitle ?? "nil") cancel=\(cancel) browser=\(browser) buttons=\(buttons.sorted()) nodes=\(visited)"

        if openTitle != nil && cancel && browser {
            return Verdict(isPicker: true, reason: summary, buttonTitle: openTitle)
        }
        return Verdict(isPicker: false, reason: summary)
    }

    static func defaultButtonTitle(_ window: AXUIElement) -> String? {
        AX.element(window, kAXDefaultButtonAttribute).flatMap { AX.string($0, kAXTitleAttribute) }
    }

    /// One-time dump of everything we can see on a detected picker, to learn what's reliable.
    static func logDiagnostics(_ window: AXUIElement) {
        let names = AX.attributeNames(window)
        Log.write("picker-diag", "attributes: \(names.joined(separator: ", "))")
        for attribute in classNameAttributes {
            let value = AX.value(window, attribute).map { "\($0)" } ?? "nil"
            Log.write("picker-diag", "probe \(attribute) = \(value)")
        }
    }
}
