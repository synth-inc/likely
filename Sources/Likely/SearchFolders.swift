import AppKit

/// A place Likely's agent searches. The built-in ones are the macOS-protected folders most uploads
/// come from; iCloud Drive and cloud-storage folders appear when present; users can add their own.
struct SearchFolder: Identifiable, Hashable {
    let url: URL
    let name: String
    let icon: String
    let why: String
    let isCustom: Bool

    var id: URL { url }

    static var all: [SearchFolder] { builtIn + cloud + custom }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    private static var builtIn: [SearchFolder] {
        [
            SearchFolder(url: home.appendingPathComponent("Desktop"), name: "Desktop", icon: "menubar.dock.rectangle",
                         why: "Screenshots and things you're working on right now.", isCustom: false),
            SearchFolder(url: home.appendingPathComponent("Documents"), name: "Documents", icon: "doc.text",
                         why: "Your documents, decks and project files.", isCustom: false),
            SearchFolder(url: home.appendingPathComponent("Downloads"), name: "Downloads", icon: "arrow.down.circle",
                         why: "Recent downloads are often exactly what you're uploading.", isCustom: false),
        ]
    }

    /// iCloud Drive plus Google Drive / Dropbox / OneDrive / Box (~/Library/CloudStorage), when installed.
    private static var cloud: [SearchFolder] {
        let fm = FileManager.default
        var folders: [SearchFolder] = []
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            folders.append(SearchFolder(url: iCloud, name: "iCloud Drive", icon: "icloud",
                                        why: "Files synced with iCloud, including Desktop and Documents if you sync those.", isCustom: false))
        }
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let names = (try? fm.contentsOfDirectory(atPath: storage.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            // Folder names look like "GoogleDrive-me@gmail.com", "Dropbox", "OneDrive-Personal", "Box-Box".
            let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
            let provider = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box"][parts[0]] ?? parts[0]
            let account = parts.count > 1 && parts[1] != parts[0] ? " (\(parts[1]))" : ""
            folders.append(SearchFolder(url: storage.appendingPathComponent(name), name: provider, icon: "externaldrive.connected.to.line.below",
                                        why: "Files in your \(provider)\(account).", isCustom: false))
        }
        return folders
    }

    private static var custom: [SearchFolder] {
        Settings.extraSearchFolders.map { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let display = (path as NSString).abbreviatingWithTildeInPath
            return SearchFolder(url: url, name: url.lastPathComponent, icon: path.hasPrefix("/Volumes/") ? "externaldrive" : "folder",
                                why: display, isCustom: true)
        }
    }

    /// Asks the user for a folder to add. Returns it, or nil if cancelled / already listed.
    static func chooseCustom() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder Likely should search."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              !all.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return nil }
        Settings.extraSearchFolders.append(url.path)
        Log.write("folders", "added search folder \(url.path)")
        return url
    }

    static func removeCustom(_ folder: SearchFolder) {
        Settings.extraSearchFolders.removeAll { $0 == folder.url.path }
    }

    /// For the prompt: every folder, with a marker for the ones the user explicitly added.
    static var promptDescription: String {
        all.map { ($0.url.path as NSString).abbreviatingWithTildeInPath + ($0.isCustom ? " (added by the user)" : "") }
            .joined(separator: ", ")
    }

    /// Folders outside the home directory, which the agent needs explicit access to.
    static var outsideHome: [String] {
        all.map(\.url.path).filter { !$0.hasPrefix(home.path + "/") }
    }
}
