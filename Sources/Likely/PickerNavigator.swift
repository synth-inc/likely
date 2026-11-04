import ApplicationServices
import Foundation

/// Points an open picker at ~/Likely by selecting the "Likely" row in its sidebar, which only exists
/// if the user pinned the folder (onboarding step 3).
enum PickerNavigator {
    /// Retries for a couple of seconds: the sidebar is often populated after the window appears.
    static func selectLikelyInSidebar(of window: AXUIElement, attempt: Int = 0, isCurrent: @escaping () -> Bool) {
        guard isCurrent(), AX.isAlive(window) else { return }
        switch trySelect(in: window) {
        case .selected:
            Log.write("navigate", "selected \"\(folderName)\" in sidebar")
        case .alreadySelected:
            Log.write("navigate", "\"\(folderName)\" already selected")
        case .notFound(let why):
            guard attempt < 8 else {
                Log.write("navigate", "gave up: \(why). Is ~/Likely pinned in the Finder sidebar?")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                selectLikelyInSidebar(of: window, attempt: attempt + 1, isCurrent: isCurrent)
            }
        }
    }

    private enum Outcome { case selected, alreadySelected, notFound(String) }

    private static var folderName: String { LikelyFolder.url.lastPathComponent }

    private static func trySelect(in window: AXUIElement) -> Outcome {
        guard let sidebar = findSidebar(in: window) else { return .notFound("no sidebar") }
        let rows = AX.elements(sidebar, kAXRowsAttribute)
        guard let row = rows.first(where: { rowTitle($0) == folderName }) else {
            return .notFound("no \"\(folderName)\" row among \(rows.count)")
        }
        if (AX.value(row, kAXSelectedAttribute) as? Bool) == true { return .alreadySelected }
        let err = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        return err == .success ? .selected : .notFound("select failed (\(err.rawValue))")
    }

    /// The sidebar is an AXOutline described as "sidebar"; failing that (other languages), the first
    /// outline found breadth-first, which is the sidebar since it sits shallower than the file list.
    static func findSidebar(in window: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var firstOutline: AXUIElement?
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if AX.string(element, kAXRoleAttribute) == kAXOutlineRole {
                if AX.string(element, kAXDescriptionAttribute) == "sidebar" { return element }
                if firstOutline == nil { firstOutline = element }
                continue
            }
            if depth < 6 { queue.append(contentsOf: AX.elements(element, kAXChildrenAttribute).map { ($0, depth + 1) }) }
        }
        return firstOutline
    }

    /// Text of the row's AXStaticText (row → cell → static text).
    private static func rowTitle(_ row: AXUIElement) -> String? {
        for cell in AX.elements(row, kAXChildrenAttribute) {
            for child in AX.elements(cell, kAXChildrenAttribute) where AX.string(child, kAXRoleAttribute) == kAXStaticTextRole {
                return AX.string(child, kAXValueAttribute)
            }
        }
        return nil
    }
}
