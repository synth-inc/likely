import ApplicationServices
import AppKit

/// Thin helpers over the AXUIElement C API.
enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func pid(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// False once the element has been destroyed. A busy app (cannotComplete) still counts as alive.
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    /// For the log: role, subrole, identifier and frame; the title (a document name, an email subject)
    /// is private.
    static func describe(_ element: AXUIElement) -> LogMessage {
        var line: LogMessage = "\(meta: string(element, kAXRoleAttribute) ?? "?")"
        if let subrole = string(element, kAXSubroleAttribute) { line = "\(line) subrole=\(meta: subrole)" }
        if let title = string(element, kAXTitleAttribute), !title.isEmpty { line = "\(line) title=\(sensitive: title)" }
        if let id = string(element, kAXIdentifierAttribute) { line = "\(line) id=\(meta: id)" }
        if let frame = frame(element) { line = "\(line) frame=\(frame)" }
        return line
    }
}
