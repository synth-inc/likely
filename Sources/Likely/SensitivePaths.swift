import Foundation

/// Which `FILE:` paths an agent suggests Likely refuses to copy into the Likely folder, where any app's
/// picker (and any website the user uploads to) could pick them up. A prompt-injected or confused agent
/// shouldn't be able to stage SSH keys, cloud credentials or keychains next to the user's real files.
/// Pure path logic (no file system access) so scripts/verify-sensitive-paths.sh can test it.
enum SensitivePaths {
    /// Under the home folder's Library, only folders holding the user's own documents are fine.
    static let allowedLibraryFolders = ["Library/CloudStorage", "Library/Mobile Documents"]

    /// System locations that never hold something a user means to upload.
    static let blockedRoots = ["/etc", "/private", "/var", "/tmp", "/dev", "/cores", "/System", "/usr", "/bin", "/sbin",
                               "/Library/Keychains", "/Library/Application Support", "/Library/Preferences"]

    /// Why `path` (absolute, symlinks already resolved) must not be copied, or nil if it's fine.
    static func refusalReason(for path: String, home: String) -> String? {
        let path = (path as NSString).standardizingPath
        let lower = path.lowercased()
        let home = (home as NSString).standardizingPath
        let lowerHome = home.lowercased()

        // Dotfiles and anything inside a dot-folder: ~/.ssh, ~/.aws, ~/.config, ~/.gnupg, .env, .git, …
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return "hidden file or folder" }

        for root in blockedRoots where lower == root.lowercased() || lower.hasPrefix(root.lowercased() + "/") {
            return "system location \(root)"
        }
        // Keychains anywhere (other users' homes, external volumes).
        if lower.contains("/keychains/") || lower.hasSuffix(".keychain") || lower.hasSuffix(".keychain-db") { return "keychain" }

        let library = lowerHome + "/library"
        if lower == library || lower.hasPrefix(library + "/") {
            let allowed = allowedLibraryFolders.contains { folder in
                let prefix = (lowerHome + "/" + folder).lowercased()
                return lower.hasPrefix(prefix + "/")
            }
            if !allowed { return "inside ~/Library" }
        }
        return nil
    }
}
