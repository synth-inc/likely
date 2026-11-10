//
//  CopyEditor.swift
//  OnboardingKit
//
//  Temporary copy-editing mode: onboarding text becomes editable in place, and "Save" writes the
//  changes (original → edited, plus free-form notes) to a JSON file a developer can apply to the code.
//  Turn on with `defaults write <bundle id> OnboardingKit.editCopy -bool true`.
//

import AppKit
import SwiftUI

public final class CopyEditor: ObservableObject {
    public static let shared = CopyEditor()

    @Published public var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published public private(set) var edits: [String: String] = [:]
    @Published public var notes = ""
    /// Numeric style tweaks (font sizes, weight/design indexes), keyed like "license.price.size".
    @Published public private(set) var styles: [String: Double] = [:]
    @Published public private(set) var lastSaved: Date?

    /// Where Save writes (and edits reload from). Apps can point this at their own debug folder.
    public var saveURL: URL {
        didSet { load() }
    }

    private static let enabledKey = "OnboardingKit.editCopy"

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let bundleID = Bundle.main.bundleIdentifier ?? "OnboardingKit"
        saveURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(bundleID)/onboarding-copy.json")
        load()
    }

    /// The (possibly edited) text for a piece of copy. The original string is the key.
    public func text(_ original: String) -> String { edits[original] ?? original }

    public func binding(_ original: String) -> Binding<String> {
        Binding(get: { self.text(original) },
                set: { newValue in self.edits[original] = newValue == original ? nil : newValue })
    }

    public func style(_ key: String, _ defaultValue: Double) -> Double { styles[key] ?? defaultValue }

    public func styleBinding(_ key: String, _ defaultValue: Double) -> Binding<Double> {
        Binding(get: { self.style(key, defaultValue) },
                set: { newValue in self.styles[key] = newValue == defaultValue ? nil : newValue })
    }

    public func resetStyles(withPrefix prefix: String) {
        for key in styles.keys where key.hasPrefix(prefix) { styles[key] = nil }
    }

    public func save() {
        let payload: [String: Any] = [
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "howToRead": "Each key in `edits` is the current text in the code; its value is the replacement.",
            "edits": edits,
            "styles": styles,
            "notes": notes,
        ]
        do {
            try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: saveURL)
            lastSaved = Date()
        } catch {
            // Domain and code only: the description names the file (NSLog goes to the unified log).
            let ns = error as NSError
            NSLog("CopyEditor: save failed: %@ %ld", ns.domain, ns.code)
        }
    }

    public func revealSaveFile() {
        NSWorkspace.shared.activateFileViewerSelecting([saveURL])
    }

    /// Edits survive relaunches (e.g. Quit & Reopen mid-onboarding).
    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        edits = json["edits"] as? [String: String] ?? [:]
        notes = json["notes"] as? String ?? ""
        styles = json["styles"] as? [String: Double] ?? [:]
    }
}

/// Text that becomes an in-place text field while copy editing is on. Style it like `Text`
/// (`.font`, `.foregroundColor`, `.multilineTextAlignment` all carry over). Supports **markdown**.
public struct EditableText: View {
    private let original: String
    @ObservedObject private var editor = CopyEditor.shared

    public init(_ original: String) {
        self.original = original
    }

    public var body: some View {
        if editor.isEnabled {
            TextField("", text: editor.binding(original), axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 3)
                .background(Color.yellow.opacity(editor.edits[original] == nil ? 0.06 : 0.16), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.yellow.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        } else {
            Text(LocalizedStringKey(editor.text(original)))
        }
    }
}

/// Floating bar shown at the top of the onboarding window in copy-editing mode.
struct CopyEditorToolbar: View {
    @ObservedObject var editor = CopyEditor.shared
    @State private var showNotes = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.line")
            Text("Editing copy").font(.system(size: 12, weight: .medium))
            Text("\(editor.edits.count + editor.styles.count) change\(editor.edits.count + editor.styles.count == 1 ? "" : "s")")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Button("Notes…") { showNotes.toggle() }
                .popover(isPresented: $showNotes, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes (button labels, layout, anything else)").font(.caption.bold())
                        TextEditor(text: $editor.notes)
                            .font(.system(size: 12))
                            .frame(width: 320, height: 160)
                    }
                    .padding(10)
                }
            Button("Save") { editor.save() }
                .keyboardShortcut("s", modifiers: .command)
            if let saved = editor.lastSaved {
                Button("Saved \(saved.formatted(date: .omitted, time: .shortened)) ↗") { editor.revealSaveFile() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Button {
                editor.isEnabled = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Turn off copy editing")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.yellow.opacity(0.6)))
        .padding(.top, 8)
    }
}

// MARK: - Style tweaking

/// A tweakable style value shown in `StyleTweaker`.
public enum StyleControl {
    case size(key: String, label: String, defaultValue: Double, range: ClosedRange<Double> = 9...32)
    case choice(key: String, label: String, options: [String], defaultIndex: Int)
}

public enum StyleOptions {
    public static let weights: [(String, Font.Weight)] = [
        ("Light", .light), ("Regular", .regular), ("Medium", .medium), ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy),
    ]
    public static let designs: [(String, Font.Design)] = [
        ("Default", .default), ("Rounded", .rounded), ("Serif", .serif), ("Mono", .monospaced),
    ]

    /// Font from tweakable size / weight index / design index keys under `prefix` ("…size", "…weight", "…design").
    public static func font(_ prefix: String, size: Double, weight: Font.Weight, design: Font.Design = .default) -> Font {
        let editor = CopyEditor.shared
        let defaultWeight = Double(weights.firstIndex { $0.1 == weight } ?? 1)
        let defaultDesign = Double(designs.firstIndex { $0.1 == design } ?? 0)
        let w = weights[min(max(Int(editor.style(prefix + ".weight", defaultWeight)), 0), weights.count - 1)].1
        let d = designs[min(max(Int(editor.style(prefix + ".design", defaultDesign)), 0), designs.count - 1)].1
        return .system(size: editor.style(prefix + ".size", size), weight: w, design: d)
    }

    /// The size/weight/design controls for a `font(_:size:weight:design:)` prefix.
    public static func controls(_ prefix: String, label: String, size: Double, weight: Font.Weight,
                                design: Font.Design = .default) -> [StyleControl] {
        [
            .size(key: prefix + ".size", label: "\(label) size", defaultValue: size),
            .choice(key: prefix + ".weight", label: "\(label) weight", options: weights.map(\.0),
                    defaultIndex: weights.firstIndex { $0.1 == weight } ?? 1),
            .choice(key: prefix + ".design", label: "\(label) font", options: designs.map(\.0),
                    defaultIndex: designs.firstIndex { $0.1 == design } ?? 0),
        ]
    }
}

/// Sliders and pickers for live font tweaks; values save with the copy edits.
public struct StyleTweaker: View {
    let title: String
    let prefix: String
    let controls: [StyleControl]
    @ObservedObject private var editor = CopyEditor.shared

    public init(title: String, prefix: String, controls: [StyleControl]) {
        self.title = title
        self.prefix = prefix
        self.controls = controls
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Reset") { editor.resetStyles(withPrefix: prefix) }.controlSize(.small)
            }
            ForEach(Array(controls.enumerated()), id: \.offset) { _, control in
                switch control {
                case let .size(key, label, defaultValue, range):
                    let binding = editor.styleBinding(key, defaultValue)
                    HStack {
                        Text(label).font(.system(size: 11)).frame(width: 120, alignment: .leading)
                        Slider(value: binding, in: range, step: 0.5)
                        Text(String(format: "%.1f", binding.wrappedValue)).font(.system(size: 11).monospacedDigit()).frame(width: 34)
                    }
                case let .choice(key, label, options, defaultIndex):
                    HStack {
                        Text(label).font(.system(size: 11)).frame(width: 120, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { Int(editor.style(key, Double(defaultIndex))) },
                            set: { editor.styleBinding(key, Double(defaultIndex)).wrappedValue = Double($0) })) {
                            ForEach(Array(options.enumerated()), id: \.offset) { index, option in Text(option).tag(index) }
                        }
                        .labelsHidden()
                    }
                }
            }
            Text("Saved with your copy edits (⌘S).").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 340)
    }
}
