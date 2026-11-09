import Foundation

/// macOS-protected stores of other apps' data that the search agents are kept out of by default.
///
/// Agents run as children of Likely, so macOS attributes their file access to Likely. A Glob or `find`
/// over ~ that walks into ~/Library/Photos/Libraries/Syndication.photoslibrary (Shared with You) or
/// ~/Library/Containers makes macOS show "Likely would like to access your Photos" (or "data from other
/// apps") in the middle of an unrelated search. Likely itself never needs these. So every agent sandbox
/// denies reading them (`sandboxRules`, `AgentSandbox.codexFilesystem`) unless the user turns an area
/// on in Settings → Permissions → Private data, or approves a tool that declares it in `needs`.
public enum PrivateDataArea: String, CaseIterable, Codable, Identifiable, Hashable {
    case photos
    case mail
    case messages
    case contacts
    case safari
    case appData = "app-data"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .photos: return "Photos"
        case .mail: return "Mail"
        case .messages: return "Messages"
        case .contacts: return "Contacts & Calendars"
        case .safari: return "Safari"
        case .appData: return "Other apps' private data"
        }
    }

    /// For sentences: "<tool> needs access to your Photos".
    public var phrase: String {
        switch self {
        case .appData: return "other apps' private data"
        case .safari: return "your Safari data"
        default: return "your " + title
        }
    }

    public var detail: String {
        switch self {
        case .photos: return "Photos libraries (including Shared with You)."
        case .mail: return "Mail's messages and attachments."
        case .messages: return "Messages history and attachments."
        case .contacts: return "Contacts, Calendar and Reminders data."
        case .safari: return "Safari history, bookmarks and cookies."
        case .appData: return "Other apps' containers (~/Library/Containers, Group Containers)."
        }
    }

    /// Folders under the home folder (relative paths). Areas that live partly inside other apps'
    /// containers list those too, so allowing "Other apps' private data" doesn't open Mail.
    public var homeRelativePaths: [String] {
        switch self {
        case .photos:
            return ["Library/Photos", "Pictures/Photos Library.photoslibrary",
                    "Library/Containers/com.apple.Photos", "Library/Group Containers/group.com.apple.photos"]
        case .mail:
            return ["Library/Mail", "Library/Containers/com.apple.mail", "Library/Group Containers/group.com.apple.mail"]
        case .messages:
            return ["Library/Messages", "Library/Containers/com.apple.MobileSMS", "Library/Containers/com.apple.iChat"]
        case .contacts:
            return ["Library/Application Support/AddressBook", "Library/Calendars", "Library/Reminders",
                    "Library/Containers/com.apple.AddressBook", "Library/Containers/com.apple.iCal",
                    "Library/Containers/com.apple.reminders", "Library/Group Containers/group.com.apple.calendar",
                    "Library/Group Containers/group.com.apple.reminders"]
        case .safari:
            return ["Library/Safari", "Library/Cookies", "Library/Containers/com.apple.Safari", "Library/WebKit/com.apple.Safari"]
        case .appData:
            return ["Library/Containers", "Library/Group Containers"]
        }
    }

    /// Seatbelt regexes for stores that can be anywhere: a Photos library can be on an external drive
    /// or in any folder, and is a `.photoslibrary` package wherever it is.
    public var regexes: [String] {
        switch self {
        case .photos: return [#"\.[Pp][Hh][Oo][Tt][Oo][Ss][Ll][Ii][Bb][Rr][Aa][Rr][Yy](/|$)"#]
        default: return []
        }
    }

    /// Whether macOS has a permission alert for it. Mail, Messages and Safari data are only ever
    /// readable with Full Disk Access: macOS never asks, it just refuses.
    public var needsFullDiskAccess: Bool {
        switch self {
        case .mail, .messages, .safari: return true
        default: return false
        }
    }

    public func paths(home: String) -> [String] {
        homeRelativePaths.map { home + "/" + $0 }
    }

    /// An area by its id in tools.json (`"needs": ["photos"]`). A few obvious synonyms are accepted.
    public init?(id: String) {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "photos", "photo", "photos-library": self = .photos
        case "mail", "email": self = .mail
        case "messages", "imessage": self = .messages
        case "contacts", "calendars", "calendar", "reminders", "contacts-calendars": self = .contacts
        case "safari": self = .safari
        case "app-data", "appdata", "containers": self = .appData
        default: return nil
        }
    }
}

/// Which areas the user has opened to the agents (UserDefaults: agents can't write Likely's
/// preferences, see AgentSandbox.protectionRules). All off by default.
public enum PrivateDataAccess {
    public static let defaultsPrefix = "privateDataAllowed."

    public static func key(_ area: PrivateDataArea) -> String { defaultsPrefix + area.rawValue }

    public static func isAllowed(_ area: PrivateDataArea, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(area))
    }

    public static func setAllowed(_ allowed: Bool, _ area: PrivateDataArea, defaults: UserDefaults = .standard) {
        defaults.set(allowed, forKey: key(area))
    }

    /// The areas agents are kept out of right now.
    public static func blocked(defaults: UserDefaults = .standard) -> [PrivateDataArea] {
        PrivateDataArea.allCases.filter { !isAllowed($0, defaults: defaults) }
    }

    /// `(deny file-read* …)` for `blocked`, or "" when every area is allowed. Paths are real paths
    /// (seatbelt matches those). Allowed areas get no rule at all, so a container another area keeps
    /// closed (e.g. Mail's) stays closed even with "Other apps' private data" on.
    public static func sandboxRules(blocked: [PrivateDataArea], home: String) -> String {
        guard !blocked.isEmpty else { return "" }
        let realHome = AgentSandbox.realPath(home)
        var filters: [String] = []
        for area in blocked {
            filters += area.paths(home: realHome).map { "(subpath \(AgentSandbox.quoted($0)))" }
            filters += area.regexes.map { "(regex \(AgentSandbox.quoted($0)))" }
        }
        return "(deny file-read* \(filters.joined(separator: " ")))"
    }

    /// Codex's permission table entries ("none") for `blocked`. Codex can't express the
    /// `.photoslibrary`-anywhere regex; the default library locations are listed instead.
    public static func codexPaths(blocked: [PrivateDataArea], home: String) -> [String] {
        let realHome = AgentSandbox.realPath(home)
        return blocked.flatMap { $0.paths(home: realHome) }
    }

    /// Needs from tools.json that aren't an area id.
    public static func unknownNeeds(_ needs: [String]) -> [String] {
        needs.filter { PrivateDataArea(id: $0) == nil }
    }

    /// The areas a tool needs that are still blocked.
    public static func unmetNeeds(of tool: CustomTool, defaults: UserDefaults = .standard) -> [PrivateDataArea] {
        tool.neededAreas.filter { !isAllowed($0, defaults: defaults) }
    }
}
