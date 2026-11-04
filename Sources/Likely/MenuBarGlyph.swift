import AppKit

/// The menu bar icon: Resources/MenuBarGlyph.pdf (a black-on-transparent template, so swapping the
/// layout is a one-file change), with a small dot while searching and dimmed while inactive.
///
/// Dev builds (`./build.sh`, LIKELY_DEV) also bundle the candidate layouts in Resources/MenuBarGlyphs
/// and let Settings → Debug or the menu's Debug submenu switch between them (`debugMenuBarGlyph`).
enum MenuBarGlyph {
    static let didChange = Notification.Name("MenuBarGlyphChanged")

    struct Option: Identifiable, Hashable {
        let id: String       // file name without extension
        let title: String
    }

    /// Candidates bundled in dev builds, with the icon editor's descriptions.
    static let candidates: [Option] = [
        Option(id: "glyph-12e-filled", title: "12e filled — default (wider-set eyes, solid folded corner)"),
        Option(id: "glyph-03-solo", title: "03 — solo (one raised brow in the page)"),
        Option(id: "glyph-04-knockout", title: "04 — knockout (solid page, brows knocked out)"),
        Option(id: "glyph-08-faceOnly", title: "08 — face only, no page"),
        Option(id: "glyph-12-faceDots", title: "12 — page + dot eyes + flat mouth"),
        Option(id: "glyph-12a", title: "12a — eyes +20%, mouth −30%"),
        Option(id: "glyph-12b", title: "12b — eyes raised 1 pt (more forehead)"),
        Option(id: "glyph-12c", title: "12c — eyes lowered 0.8 pt, mouth 0.4 pt closer"),
        Option(id: "glyph-12d", title: "12d — eyes 20% closer together"),
        Option(id: "glyph-12e", title: "12e — eyes 20% wider apart"),
        Option(id: "glyph-12f", title: "12f — mouth 30% longer, thinner line"),
        Option(id: "glyph-12g", title: "12g — mouth 1.2 pt closer to eyes, thicker line"),
        Option(id: "glyph-12h", title: "12h — whole face 1 pt lower"),
        Option(id: "glyph-12i", title: "12i — face nudged down-left, right eye higher"),
        Option(id: "glyph-12j", title: "12j — page 10% narrower"),
    ]

    static var isDebugEnabled: Bool {
        #if LIKELY_DEV
        return true
        #else
        return false
        #endif
    }

    /// Candidates actually present in the bundle (dev builds only).
    static var available: [Option] {
        guard isDebugEnabled else { return [] }
        return candidates.filter { url(for: $0.id) != nil }
    }

    static func url(for id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: "pdf", subdirectory: "MenuBarGlyphs")
    }

    /// nil = the shipped default (MenuBarGlyph.pdf).
    static var debugSelection: String? {
        get { isDebugEnabled ? UserDefaults.standard.string(forKey: "debugMenuBarGlyph") : nil }
        set {
            UserDefaults.standard.set(newValue, forKey: "debugMenuBarGlyph")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Steps through the default and the candidates (Debug menu).
    static func cycle(by step: Int) {
        let ids: [String?] = [nil] + available.map(\.id)
        let index = ids.firstIndex(of: debugSelection) ?? 0
        debugSelection = ids[(index + step + ids.count) % ids.count]
        Log.write("app", "menu bar glyph: \(debugSelection ?? "default")")
    }

    static func baseImage(id: String? = debugSelection) -> NSImage? {
        let url = id.flatMap(url(for:)) ?? Bundle.main.url(forResource: "MenuBarGlyph", withExtension: "pdf")
        return url.flatMap(NSImage.init(contentsOf:))
    }

    static let size = NSSize(width: 18, height: 18)

    enum Badge { case none, dot }

    /// Template image for the status item. Falls back to SF Symbols when the bundle has no glyph
    /// (e.g. `swift run` without build.sh).
    static func image(badge: Badge, dimmed: Bool, fallbackSymbol: String) -> NSImage? {
        guard let base = baseImage() else {
            let image = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: "Likely")
            image?.isTemplate = true
            return image
        }
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.45 : 1)
            if badge == .dot {
                // Punch a ring, then fill a dot: reads as a status badge in both light and dark menu bars.
                let dot = NSRect(x: rect.maxX - 7, y: rect.minY, width: 7, height: 7)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Likely"
        return image
    }
}
