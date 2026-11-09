import Foundation

/// macOS-protected stores of other apps' data that the search agents are kept out of by default.
///
/// Agents run as children of Likely, so macOS attributes their file access to Likely. A Glob or `find`
/// over ~ that walks into ~/Library/Photos/Libraries/Syndication.photoslibrary (Shared with You) or
/// ~/Library/Containers makes macOS show "Likely would like to access your Photos" (or "data from other
/// apps") in the middle of an unrelated search. Likely itself never needs these. So every agent sandbox
/// denies reading them (`sandboxRules`, `AgentSandbox.codexFilesystem`) unless the user turns an area
/// on in Settings → Permissions → Private data, or approves a tool that declares it in `needs`.
///
/// Each area has its own folders (`homeRelativePaths`) and its folders inside other apps' containers
/// (`containerNames`, matched by name under ~/Library/Containers and ~/Library/Group Containers), so
/// turning an area on opens its containers even while "Other apps' private data" is off, and turning
/// that one on doesn't open an area that's still off. Stores only Full Disk Access opens, which no
/// toggle is about (call history, Biome, the TCC database, …), are always denied
/// (`alwaysDeniedPaths`).
public enum PrivateDataArea: String, CaseIterable, Codable, Identifiable, Hashable {
    case photos
    case mail
    case messages
    case contacts
    case notes
    case safari
    case appData = "app-data"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .photos: return "Photos"
        case .mail: return "Mail"
        case .messages: return "Messages"
        case .contacts: return "Contacts & Calendars"
        case .notes: return "Notes"
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
        case .notes: return "Notes and their attachments."
        case .safari: return "Safari history and bookmarks."
        case .appData: return "Other apps' containers (~/Library/Containers, Group Containers)."
        }
    }

    /// The area's own folders under the home folder (relative paths): what the permission probe reads.
    /// Its folders inside other apps' containers are `containerNames`.
    public var homeRelativePaths: [String] {
        switch self {
        case .photos: return ["Library/Photos", "Pictures/Photos Library.photoslibrary"]
        case .mail: return ["Library/Mail"]
        case .messages: return ["Library/Messages"]
        case .contacts: return ["Library/Application Support/AddressBook", "Library/Calendars", "Library/Reminders"]
        case .notes: return ["Library/Group Containers/group.com.apple.notes"]
        case .safari: return ["Library/Safari", "Library/WebKit/com.apple.Safari"]
        case .appData: return ["Library/Containers", "Library/Group Containers"]
        }
    }

    /// Anchored regexes (ICU and Seatbelt alike) over the names of the area's folders in
    /// ~/Library/Containers and ~/Library/Group Containers. Covers the names found on macOS 26.3.
    public var containerNames: [String] {
        switch self {
        case .photos:
            return [#"com\.apple\.photolibraryd"#, #"com\.apple\.photoanalysisd"#, #"com\.apple\.mediaanalysisd"#,
                    #"com\.apple\.Photos(\..+)?"#, #"com\.apple\.CloudPhotosConfiguration"#,
                    #"group\.com\.apple\.photolibraryd\.private"#, #"group\.com\.apple\.Photos\.PhotosFileProvider"#,
                    #"group\.com\.apple\.mobileslideshow\.PhotosFileProvider"#, #"group\.com\.apple\.photos"#]
        case .mail:
            return [#"com\.apple\.mail(\..+)?"#, #"com\.apple\.MailPersonaStorage"#, #"com\.apple\.MailCacheDelete"#,
                    #"group\.com\.apple\.mail"#]
        case .messages:
            return [#"com\.apple\.messages(\..+)?"#, #"com\.apple\.MessagesLegacyTransferArchive"#,
                    #"com\.apple\.MobileSMS(\..+)?"#, #"com\.apple\.iChat"#, #"group\.com\.apple\.messages"#]
        case .contacts:
            return [#"group\.com\.apple\.contacts"#, #"com\.apple\.AddressBook(\..+)?"#, #"com\.apple\.iCal(\..+)?"#,
                    #"com\.apple\.reminders(\..+)?"#, #"group\.com\.apple\.calendar"#, #"group\.com\.apple\.reminders"#]
        case .notes:
            return [#"group\.com\.apple\.notes"#, #"com\.apple\.Notes"#]
        case .safari:
            return [#"com\.apple\.Safari(\..+)?"#]
        case .appData:
            return []
        }
    }

    /// One alternation of `containerNames`, or nil.
    var containerNamePattern: String? {
        containerNames.isEmpty ? nil : "(" + containerNames.joined(separator: "|") + ")"
    }

    /// The Seatbelt regex for the area's container folders under `home` (a real path), or nil.
    public func containerRegex(home: String) -> String? {
        containerNamePattern.map {
            "^" + NSRegularExpression.escapedPattern(for: home) + "/Library/(Group )?Containers/" + $0 + "(/|$)"
        }
    }

    /// Whether a folder in ~/Library/Containers or Group Containers belongs to this area.
    public func ownsContainer(named name: String) -> Bool {
        guard let pattern = containerNamePattern else { return false }
        return name.range(of: "^" + pattern + "$", options: .regularExpression) != nil
    }

    /// The area that owns a container folder, if any (other than app data).
    public static func owner(ofContainer name: String) -> PrivateDataArea? {
        allCases.first { $0.ownsContainer(named: name) }
    }

    /// Seatbelt regexes for stores that can be anywhere: a Photos library can be on an external drive
    /// or in any folder, and is a `.photoslibrary` package wherever it is.
    public var regexes: [String] {
        switch self {
        case .photos: return [#"\.[Pp][Hh][Oo][Tt][Oo][Ss][Ll][Ii][Bb][Rr][Aa][Rr][Yy](/|$)"#]
        default: return []
        }
    }

    /// Whether only Full Disk Access opens it: macOS has no permission alert for Mail, Messages and
    /// Safari data, it just refuses. Full Disk Access is granted to Likely, and agents run as Likely, so
    /// once it's on, turning one of these areas on lets the agents read it too.
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
        case "notes", "apple-notes": self = .notes
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

    /// Stores only Full Disk Access opens, denied to every agent whatever the toggles say: none of the
    /// areas is about them, and with Full Disk Access granted to Likely the agents could otherwise read
    /// them (call history, the TCC database, Biome and Knowledge activity, iPhone backups, accounts,
    /// cookies, …). Relative to the home folder.
    public static let alwaysDeniedRelativePaths = [
        "Library/Application Support/com.apple.TCC", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/Knowledge", "Library/Biome", "Library/Suggestions",
        "Library/Application Support/MobileSync/Backup", "Library/Accounts", "Library/IdentityServices",
        "Library/HomeKit", "Library/Metadata/CoreSpotlight", "Library/Application Support/FaceTime", "Library/Cookies",
    ]

    /// ~/Library/Keychains: the login keychain file itself stays readable to sandbox-exec agents
    /// (Claude Code reads its sign-in from it in-process; it's encrypted with the login password), its
    /// subfolders don't (the data-protection keychain, which holds Likely's data key). Codex's
    /// commands get none of it (Codex itself runs outside its sandbox).
    public static func keychainSubfoldersRegex(home: String) -> String {
        "^" + NSRegularExpression.escapedPattern(for: home + "/Library/Keychains/") + "[^/]+/"
    }

    public static func alwaysDeniedPaths(home: String) -> [String] {
        alwaysDeniedRelativePaths.map { home + "/" + $0 }
    }

    /// The Seatbelt rules for `blocked` (last match wins, so the order matters):
    /// 1. while "Other apps' private data" is off: deny ~/Library/Containers and Group Containers,
    ///    except the containers of the areas that are on (a `require-not`, rather than an `allow`
    ///    after it, which would also undo an eval's isolation rules that come before these);
    /// 2. deny each blocked area: its folders, its containers (also when app data is on), and for
    ///    Photos any `.photoslibrary`;
    /// 3. always deny the Full-Disk-Access-only stores and the keychain's subfolders.
    /// Paths are real paths (Seatbelt matches those).
    public static func sandboxRules(blocked: [PrivateDataArea], home: String) -> String {
        let realHome = AgentSandbox.realPath(home)
        var rules: [String] = []
        if blocked.contains(.appData) {
            let containers = PrivateDataArea.appData.paths(home: realHome).map { "(subpath \(AgentSandbox.quoted($0)))" }.joined(separator: " ")
            let open = PrivateDataArea.allCases.filter { $0 != .appData && !blocked.contains($0) }
                .compactMap { $0.containerRegex(home: realHome) }
            if open.isEmpty {
                rules.append("(deny file-read* \(containers))")
            } else {
                let exceptions = open.map { "(require-not (regex \(AgentSandbox.quoted($0))))" }.joined(separator: " ")
                rules.append("(deny file-read* (require-all (require-any \(containers)) \(exceptions)))")
            }
        }
        var filters: [String] = []
        for area in blocked where area != .appData {
            filters += area.paths(home: realHome).map { "(subpath \(AgentSandbox.quoted($0)))" }
            filters += [area.containerRegex(home: realHome)].compactMap { $0 }.map { "(regex \(AgentSandbox.quoted($0)))" }
            filters += area.regexes.map { "(regex \(AgentSandbox.quoted($0)))" }
        }
        if !filters.isEmpty { rules.append("(deny file-read* \(filters.joined(separator: " ")))") }
        let always = alwaysDeniedPaths(home: realHome).map { "(subpath \(AgentSandbox.quoted($0)))" }
            + ["(regex \(AgentSandbox.quoted(keychainSubfoldersRegex(home: realHome))))"]
        rules.append("(deny file-read* \(always.joined(separator: " ")))")
        return rules.joined(separator: "\n")
    }

    /// Codex's permission table entries for `blocked`: path → "none" or "read" (the more specific path
    /// wins). Codex has no regexes, so container folders are found by listing ~/Library/Containers and
    /// Group Containers (free: only reading inside one is protected), and Photos libraries outside the
    /// default places come from `photoLibraries` (PhotoLibraryScan, found at launch).
    public static func codexEntries(blocked: [PrivateDataArea], home: String, photoLibraries: [String] = []) -> [(path: String, access: String)] {
        let realHome = AgentSandbox.realPath(home)
        let containers = PrivateDataArea.appData.paths(home: realHome)
        var found: [(path: String, owner: PrivateDataArea?)] = []
        for root in containers {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() {
                found.append((root + "/" + name, PrivateDataArea.owner(ofContainer: name)))
            }
        }
        var entries: [(path: String, access: String)] = []
        func add(_ path: String, _ access: String) {
            if let i = entries.firstIndex(where: { $0.path == path }) {
                if access == "none" { entries[i].access = "none" }   // a deny never loses to a read
            } else {
                entries.append((path, access))
            }
        }
        if blocked.contains(.appData) {
            containers.forEach { add($0, "none") }
            for (path, owner) in found { if let owner, !blocked.contains(owner) { add(path, "read") } }
        }
        for area in blocked where area != .appData {
            area.paths(home: realHome).forEach { add($0, "none") }
            for (path, owner) in found where owner == area { add(path, "none") }
            if area == .photos { photoLibraries.map(AgentSandbox.realPath).forEach { add($0, "none") } }
        }
        alwaysDeniedPaths(home: realHome).forEach { add($0, "none") }
        add(realHome + "/Library/Keychains", "none")
        return entries
    }

    /// Needs from tools.json that aren't an area id.
    public static func unknownNeeds(_ needs: [String]) -> [String] {
        needs.filter { PrivateDataArea(id: $0) == nil }
    }

    /// The areas a tool needs that are still blocked.
    public static func unmetNeeds(of tool: CustomTool, defaults: UserDefaults = .standard) -> [PrivateDataArea] {
        unmetNeeds(of: tool) { isAllowed($0, defaults: defaults) }
    }

    public static func unmetNeeds(of tool: CustomTool, allowed: (PrivateDataArea) -> Bool) -> [PrivateDataArea] {
        tool.neededAreas.filter { !allowed($0) }
    }

    /// The tools the agent gets: enabled, valid, approved, and every area they need turned on. A tool
    /// whose areas are still off isn't used: its commands would fail in the sandbox, and the user
    /// hasn't agreed to open them.
    public static func activeTools(_ tools: [CustomTool], approvals: ToolApproval.Approvals,
                                   allowed: (PrivateDataArea) -> Bool) -> [CustomTool] {
        ToolApproval.usable(tools, approvals: approvals).filter { unmetNeeds(of: $0, allowed: allowed).isEmpty }
    }
}

/// Photos libraries outside the default places (a `.photoslibrary` package in any folder, or on an
/// external drive), for Codex, whose permission table can't say "any `.photoslibrary`". Found by
/// walking the home folder a few levels deep and each volume shallowly, without entering packages,
/// hidden folders, ~/Library (its libraries are under ~/Library/Photos, denied as a whole) or
/// cloud and network storage.
public enum PhotoLibraryScan {
    public static let homeDepth = 3
    public static let volumeDepth = 2
    static let skippedNames: Set<String> = ["Library", "node_modules", ".git", "Applications"]

    public static func find(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                            volumes: String = "/Volumes") -> [String] {
        var found: [String] = []
        walk(home, depth: homeDepth, into: &found)
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: volumes)) ?? []).sorted() where !name.hasPrefix(".") {
            let volume = URL(fileURLWithPath: volumes).appendingPathComponent(name)
            // Local volumes only (the boot volume's link to / is skipped as a link).
            let values = try? volume.resourceValues(forKeys: [.isSymbolicLinkKey, .volumeIsLocalKey])
            guard values?.isSymbolicLink != true, values?.volumeIsLocal != false else { continue }
            walk(volume.path, depth: volumeDepth, into: &found)
        }
        return found
    }

    static func walk(_ folder: String, depth: Int, into found: inout [String]) {
        guard depth > 0 else { return }
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted() where !name.hasPrefix(".") {
            let path = folder + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }   // no links
            if name.lowercased().hasSuffix(".photoslibrary") {
                found.append(path)
            } else if !skippedNames.contains(name), !isPackage(name) {
                walk(path, depth: depth - 1, into: &found)
            }
        }
    }

    /// Packages (apps, bundles, other libraries) aren't entered.
    static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
                "fcpbundle", "logicx", "band", "noindex", "xcodeproj", "xcworkspace", "pkg", "plugin"].contains(ext)
    }
}
