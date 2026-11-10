import CryptoKit
import Foundation

// What Likely's log may contain. See docs/PRIVACY.md ("The log").
//
// A log line is a `LogMessage`, written as a string literal with interpolations. Its literal type is
// `StaticString`, so a `String` can't become a line, and every interpolated value has to say what it is
// or the line doesn't compile:
//
//     Log.write("picker", "OPENED in \(meta: appName) after \(ms) ms title=\(sensitive: title)")
//     Log.write("likely", "added \(path: source)")                 // <#3f9a2c1d .pdf>
//     Log.write("likely", "copy failed: \(error: error)")         // NSCocoaErrorDomain 513 (<#…>)
//     Log.write("agent", "turn \(public: ok ? "done" : "failed")") // constants only
//
// - bare `\(x)`: numbers, booleans, CGRect and the other `LogSafe` types (declared in this file only).
// - `public:` a `StaticString`: a constant, or a choice between constants.
// - `meta:` a runtime string that's non-identifying metadata (the picker's host app, an agent or model
//   name, an accessibility role). Each use is on a reviewed list (LogPrivacySourceTests).
// - `sensitive:` what the user typed, window titles, agent text, prompt content: private.
// - `path:` file paths and names: private, but keeps the extension.
// - `error:` the error's domain and code; its description (which often names a file) is private.
// - `errno:` a C error number and its fixed message.
//
// Private values render as a short hash (`<#3f9a2c1d>`), the same for the same value within one run of
// the app, so related lines can be followed without showing the value. The salt is random per launch,
// so the hashes can't be matched against guesses across logs. With "Log details for troubleshooting" on
// (or in dev builds) they render as they are.

/// A value that's safe in the log as it is. Conformances live in this file only, each with its own
/// `logDescription` (LogPrivacySourceTests checks both): an enum case carrying text must leave the text out.
public protocol LogSafe {
    var logDescription: String { get }
}

extension Int: LogSafe { public var logDescription: String { String(self) } }
extension Int32: LogSafe { public var logDescription: String { String(self) } }
extension Int64: LogSafe { public var logDescription: String { String(self) } }
extension UInt: LogSafe { public var logDescription: String { String(self) } }
extension UInt32: LogSafe { public var logDescription: String { String(self) } }
extension UInt64: LogSafe { public var logDescription: String { String(self) } }
extension Double: LogSafe { public var logDescription: String { String(self) } }
extension Float: LogSafe { public var logDescription: String { String(self) } }
extension Bool: LogSafe { public var logDescription: String { self ? "true" : "false" } }
extension CGFloat: LogSafe { public var logDescription: String { String(Double(self)) } }
extension CGRect: LogSafe {
    public var logDescription: String {
        "\(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))x\(Int(size.height))"
    }
}
extension SpotlightExclusion.Outcome: LogSafe {
    /// `.skipped`'s reason names paths: left out.
    public var logDescription: String {
        switch self {
        case .alreadyExcluded: return "alreadyExcluded"
        case .excluded: return "excluded"
        case .merged: return "merged"
        case .skipped: return "skipped"
        }
    }
}

/// One log line, made of safe text and private values (see the top of this file).
public struct LogMessage: ExpressibleByStringInterpolation {
    public typealias StringLiteralType = StaticString

    enum Segment: Equatable {
        case text(String)
        /// `keepExtension`: a path, shown as its hash plus its extension when hidden.
        case sensitive(String, keepExtension: Bool)
    }

    let segments: [Segment]

    public init(stringLiteral value: StaticString) { segments = [.text(value.description)] }
    public init(stringInterpolation: StringInterpolation) { segments = stringInterpolation.segments }
    init(segments: [Segment]) { self.segments = segments }

    public struct StringInterpolation: StringInterpolationProtocol {
        public typealias StringLiteralType = StaticString

        var segments: [Segment] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            segments.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: StaticString) { text(literal.description) }

        /// Numbers, booleans and the other `LogSafe` types.
        public mutating func appendInterpolation<T: LogSafe>(_ value: T) { text(value.logDescription) }
        public mutating func appendInterpolation<T: LogSafe>(_ value: T?) { text(value?.logDescription ?? "-") }

        /// A constant, or a choice between constants (`ok ? "done" : "failed"`).
        public mutating func appendInterpolation(public value: StaticString) { text(value.description) }

        /// Non-identifying metadata known only at run time: the picker's host app, an agent or model
        /// name, an accessibility role. Reviewed use by use (LogPrivacySourceTests). nil shows as "-".
        public mutating func appendInterpolation(meta value: String?) { text(value ?? "-") }

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
            list(values, keepExtension: false)
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
            list(paths, keepExtension: true)
        }

        /// An error: its domain and code always, its description (often naming a file) only with details on.
        public mutating func appendInterpolation(error: Error) {
            let ns = error as NSError
            text("\(ns.domain) \(ns.code) (")
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

        private mutating func list(_ values: [String], keepExtension: Bool) {
            text("[")
            for (i, value) in values.enumerated() {
                if i > 0 { text(", ") }
                segments.append(.sensitive(value, keepExtension: keepExtension))
            }
            text("]")
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
    public static func joined(_ parts: [LogMessage], separator: StaticString = ", ") -> LogMessage {
        var segments: [Segment] = []
        for (i, part) in parts.enumerated() {
            if i > 0 { segments.append(.text(separator.description)) }
            segments.append(contentsOf: part.segments)
        }
        return LogMessage(segments: segments)
    }

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

    /// Whether the line has private values (so it differs with details on).
    public var hasPrivateValues: Bool {
        segments.contains { if case .sensitive = $0 { return true } else { return false } }
    }
}

/// Turns a private value into `<#3f9a2c1d>`: a salted hash (32 bits), the same for the same value within a run.
public struct LogRedactor: Sendable {
    /// Salted at random once per launch.
    public static let shared = LogRedactor(salt: SymmetricKey(size: .bits256))

    private let salt: SymmetricKey

    public init(salt: SymmetricKey) { self.salt = salt }

    public func redact(_ value: String, keepExtension: Bool = false) -> String {
        if value.isEmpty { return "<empty>" }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: salt)
        let hash = mac.prefix(4).map { String(format: "%02x", $0) }.joined()
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
///
/// Only `turnOn()` in this process turns it on: the expiry that counts is kept in memory. The stored
/// value (`defaultsKey`) only mirrors it for Settings, so something else writing Likely's preferences
/// can't turn details on.
public final class LogDetailsSwitch: @unchecked Sendable {
    public static let duration: TimeInterval = 24 * 60 * 60
    public static let defaultsKey = "logDetailsUntil"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()
    private var until: Date?
    /// Dev builds log details whatever the switch says.
    public let alwaysOn: Bool

    public init(defaults: UserDefaults = .standard, alwaysOn: Bool = false, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.alwaysOn = alwaysOn
        self.now = now
    }

    /// When the switch turns itself off; nil when it's off. An expiry further away than `duration`
    /// (the clock was set back) counts as off.
    public var expiry: Date? {
        lock.lock(); defer { lock.unlock() }
        guard let until else { return nil }
        let current = now()
        return until > current && until.timeIntervalSince(current) <= Self.duration ? until : nil
    }

    /// The switch itself (on and not expired).
    public var isSwitchedOn: Bool { expiry != nil }

    /// Whether private values are written as they are.
    public var showsDetails: Bool { alwaysOn || isSwitchedOn }

    /// On for `duration` from now.
    public func turnOn() {
        let date = now().addingTimeInterval(Self.duration)
        lock.lock(); until = date; lock.unlock()
        defaults.set(date.timeIntervalSince1970, forKey: Self.defaultsKey)
    }

    public func turnOff() {
        lock.lock(); until = nil; lock.unlock()
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// The log files.
public enum LogFile {
    /// The format the log folder's files are in; older content is deleted (see `upgrade`).
    /// 1: before redaction (plaintext queries, titles, paths). 2: redacted.
    public static let formatVersion = 2
    public static let versionFileName = "log-format"
    /// Lines written with details on, in full; deleted when details turn off.
    public static let detailsFileName = "likely-details.log"

    /// Run before the first line goes into the folder `dir` holding `log`: if its content is from an
    /// older format, deletes the log and any rotated `likely.log.*` copies, and records the current
    /// format in the folder (so a restored or copied folder is checked again). Returns whether it
    /// deleted anything.
    @discardableResult
    public static func upgrade(log url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        let versionURL = dir.appendingPathComponent(versionFileName)
        let recorded = (try? String(contentsOf: versionURL, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        guard recorded < formatVersion else { return false }
        let existed = FileManager.default.fileExists(atPath: url.path)
        clear(at: url)
        try? OwnerOnly.write(Data("\(formatVersion)\n".utf8), to: versionURL)
        return existed
    }

    /// Deletes the log and any `<name>.*` copies next to it. The next line starts a new, owner-only file.
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

/// A fixed name for why an agent failed, from its error text, so failures stay debuggable with details
/// off (the text itself is private).
public enum AgentFailureKind: String, LogSafeEnum {
    case auth, rateLimit, quota, modelNotFound, network, timeout, contextTooLong, overloaded, other

    private static let patterns: [(AgentFailureKind, [String])] = [
        (.auth, ["unauthorized", "401", "authenticat", "api key", "not logged in", "login", "credential", "permission denied", "403"]),
        (.rateLimit, ["rate limit", "rate_limit", "429", "too many requests"]),
        (.quota, ["quota", "billing", "credit", "insufficient", "usage limit", "exceeded your"]),
        (.modelNotFound, ["model not found", "unknown model", "model_not_found", "does not exist", "not supported model", "invalid model"]),
        (.overloaded, ["overloaded", "529", "503", "unavailable"]),
        (.timeout, ["timed out", "timeout", "deadline"]),
        (.contextTooLong, ["context length", "too long", "maximum context", "prompt is too long", "token limit"]),
        (.network, ["network", "connection", "econnrefused", "enotfound", "dns", "offline", "socket", "tls", "ssl"]),
    ]

    public static func classify(_ text: String) -> AgentFailureKind {
        let lower = text.lowercased()
        return patterns.first { $0.1.contains(where: lower.contains) }?.0 ?? .other
    }
}

/// An enum with only plain cases, logged by its raw value.
public protocol LogSafeEnum: LogSafe, RawRepresentable where RawValue == String {}
extension LogSafeEnum { public var logDescription: String { rawValue } }
