import CryptoKit
import Foundation

// What Likely's log may contain. See docs/PRIVACY.md ("The log").
//
// A log line is a `LogMessage`, written as a string literal with interpolations. Only values that can't
// hold personal content interpolate bare: numbers, booleans and types that adopt `LogSafe`. Anything else
// has to say what it is, or the line doesn't compile:
//
//     Log.write("picker", "OPENED in \(public: appName) after \(ms) ms title=\(sensitive: title)")
//     Log.write("likely", "added \(path: source)")                 // <#3f9a2c .pdf>
//     Log.write("likely", "copy failed: \(error: error)")         // NSCocoaErrorDomain 513
//
// - `public:` non-identifying metadata (the picker's host app, an agent or model name, a status word).
// - `sensitive:` what the user typed, window titles, agent text, prompt content: private.
// - `path:` file paths and names: private, but keeps the extension.
// - `error:` the error's domain and code; its description (which often names a file) is private.
// - `errno:` a C error number and its fixed message.
//
// Private values render as a short hash (`<#3f9a2c>`), the same for the same value within one run of the
// app, so related lines can be followed without showing the value. The salt is random per launch, so the
// hashes can't be matched against guesses across logs. With "Log details for troubleshooting" on (or in
// dev builds) they render as they are.

/// A value that's safe in the log as it is: numbers, booleans, and enums whose cases hold no user content.
/// Adopt it only for types like that; anything carrying text from the user, a window or an agent must
/// go through `sensitive:` instead.
public protocol LogSafe {
    var logDescription: String { get }
}

extension LogSafe {
    public var logDescription: String { String(describing: self) }
}

extension Int: LogSafe {}
extension Int32: LogSafe {}
extension Int64: LogSafe {}
extension UInt: LogSafe {}
extension UInt32: LogSafe {}
extension UInt64: LogSafe {}
extension Double: LogSafe {}
extension Float: LogSafe {}
extension Bool: LogSafe {}
extension CGFloat: LogSafe {}
extension SpotlightExclusion.Outcome: LogSafe {}
extension CGRect: LogSafe {
    public var logDescription: String {
        "\(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))x\(Int(size.height))"
    }
}

/// One log line, made of safe text and private values (see the top of this file).
public struct LogMessage: ExpressibleByStringInterpolation {
    enum Segment: Equatable {
        case text(String)
        /// `keepExtension`: a path, shown as its hash plus its extension when hidden.
        case sensitive(String, keepExtension: Bool)
    }

    let segments: [Segment]

    public init(stringLiteral value: String) { segments = [.text(value)] }
    public init(stringInterpolation: StringInterpolation) { segments = stringInterpolation.segments }

    public struct StringInterpolation: StringInterpolationProtocol {
        var segments: [Segment] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            segments.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: String) { text(literal) }

        /// Numbers, booleans and `LogSafe` enums.
        public mutating func appendInterpolation<T: LogSafe>(_ value: T) { text(value.logDescription) }
        public mutating func appendInterpolation<T: LogSafe>(_ value: T?) { text(value?.logDescription ?? "-") }

        /// Non-identifying metadata: the picker's host app, an agent or model name, a fixed status word.
        public mutating func appendInterpolation(public value: String?) { text(value ?? "-") }

        /// What the user typed, window titles, agent text, prompt content. nil shows as "-".
        public mutating func appendInterpolation(sensitive value: String?) {
            guard let value else { return text("-") }
            segments.append(.sensitive(value, keepExtension: false))
        }

        public mutating func appendInterpolation(sensitive value: Substring) {
            appendInterpolation(sensitive: String(value))
        }

        /// Several private values, each hashed on its own (so they match the lines about each one).
        public mutating func appendInterpolation(sensitive values: [String]) {
            text("[")
            for (i, value) in values.enumerated() {
                if i > 0 { text(", ") }
                segments.append(.sensitive(value, keepExtension: false))
            }
            text("]")
        }

        /// A file path or name: private, but its extension stays visible when hidden.
        public mutating func appendInterpolation(path: String?) {
            guard let path else { return text("-") }
            segments.append(.sensitive(path, keepExtension: true))
        }

        public mutating func appendInterpolation(path url: URL?) {
            appendInterpolation(path: url?.path)
        }

        /// Several paths, each like `path:`.
        public mutating func appendInterpolation(paths: [String]) {
            text("[")
            for (i, path) in paths.enumerated() {
                if i > 0 { text(", ") }
                segments.append(.sensitive(path, keepExtension: true))
            }
            text("]")
        }

        /// An error: its domain and code always, its description (often naming a file) only with details on.
        public mutating func appendInterpolation(error: Error) {
            let ns = error as NSError
            text("\(ns.domain) \(ns.code)")
            text(" (")
            segments.append(.sensitive(String(describing: error), keepExtension: false))
            text(")")
        }

        /// Another line's parts, private values still marked.
        public mutating func appendInterpolation(_ message: LogMessage) {
            for segment in message.segments {
                if case .text(let string) = segment { text(string) } else { segments.append(segment) }
            }
        }

        /// A C error number, with its message (a fixed table, never a path).
        public mutating func appendInterpolation(errno code: Int32) {
            text("\(String(cString: strerror(code))) (\(code))")
        }

        private mutating func text(_ string: String) {
            if case .text(let previous)? = segments.last {
                segments[segments.count - 1] = .text(previous + string)
            } else {
                segments.append(.text(string))
            }
        }
    }

    /// `parts` one after the other, `separator` between them.
    public static func joined(_ parts: [LogMessage], separator: String = ", ") -> LogMessage {
        var segments: [Segment] = []
        for (i, part) in parts.enumerated() {
            if i > 0 { segments.append(.text(separator)) }
            segments.append(contentsOf: part.segments)
        }
        return LogMessage(segments: segments)
    }

    init(segments: [Segment]) { self.segments = segments }

    /// The line as written: private values in full with `details`, hashed by `redactor` otherwise.
    public func rendered(details: Bool, redactor: LogRedactor = .shared) -> String {
        var out = ""
        for segment in segments {
            switch segment {
            case .text(let text): out += text
            case .sensitive(let value, let keepExtension):
                out += details ? value : redactor.redact(value, keepExtension: keepExtension)
            }
        }
        return out
    }
}

/// Turns a private value into `<#3f9a2c>`: a salted hash, the same for the same value within a run.
public struct LogRedactor: Sendable {
    /// Salted at random once per launch.
    public static let shared = LogRedactor(salt: SymmetricKey(size: .bits256))

    private let salt: SymmetricKey

    public init(salt: SymmetricKey) { self.salt = salt }

    public func redact(_ value: String, keepExtension: Bool = false) -> String {
        if value.isEmpty { return "<empty>" }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: salt)
        let hash = mac.prefix(3).map { String(format: "%02x", $0) }.joined()
        if keepExtension {
            let ext = (value as NSString).pathExtension
            // Only a plain short extension: anything else could be part of a name.
            if !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                return "<#\(hash) .\(ext.lowercased())>"
            }
        }
        return "<#\(hash)>"
    }
}

/// "Log details for troubleshooting": while on, private values go into the log as they are. It turns
/// itself off after `duration`, and the app turns it off when it quits (and at launch, after a crash).
/// Stored as its expiry date so the setting and the log agree without extra state.
public final class LogDetailsSwitch: @unchecked Sendable {
    public static let duration: TimeInterval = 24 * 60 * 60
    public static let defaultsKey = "logDetailsUntil"

    private let defaults: UserDefaults
    private let now: () -> Date
    /// Dev builds log details whatever the switch says.
    public let alwaysOn: Bool

    public init(defaults: UserDefaults = .standard, alwaysOn: Bool = false, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.alwaysOn = alwaysOn
        self.now = now
    }

    /// When the switch turns itself off; nil when it's off.
    public var expiry: Date? {
        let until = defaults.double(forKey: Self.defaultsKey)
        guard until > 0 else { return nil }
        let date = Date(timeIntervalSince1970: until)
        return date > now() ? date : nil
    }

    /// The switch itself (on and not expired).
    public var isSwitchedOn: Bool { expiry != nil }

    /// Whether private values are written as they are.
    public var showsDetails: Bool { alwaysOn || isSwitchedOn }

    /// On for `duration` from now.
    public func turnOn() {
        defaults.set(now().addingTimeInterval(Self.duration).timeIntervalSince1970, forKey: Self.defaultsKey)
    }

    public func turnOff() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// The log file itself.
public enum LogFile {
    /// Set once the content older versions wrote (plaintext queries, titles, paths) is gone.
    public static let legacyDiscardedKey = "logLegacyContentDiscarded"

    /// Once per Mac: empties the log at `url` (and removes old rotated copies next to it), because
    /// versions before redaction wrote what the user typed, window titles and paths into it. Returns
    /// whether it did anything this time.
    @discardableResult
    public static func discardLegacyContent(at url: URL, defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: legacyDiscardedKey) else { return false }
        clear(at: url)
        defaults.set(true, forKey: legacyDiscardedKey)
        return true
    }

    /// Deletes the log and any `likely.log.*` copies next to it. The next line starts a new, owner-only file.
    public static func clear(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + "."
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
