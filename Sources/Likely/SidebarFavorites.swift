import CoreServices
import Foundation

/// Reads and adds Finder sidebar Favorites (which also appear in every open/save panel's sidebar).
///
/// Uses the LSSharedFileList API: deprecated since macOS 10.11 but still working on macOS 26.
/// Inserting at the `kLSSharedFileListItemLast` sentinel crashes, so new items are anchored after
/// the current last favorite instead.
enum SidebarFavorites {
    private static func list() -> LSSharedFileList? {
        LSSharedFileListCreate(kCFAllocatorDefault, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue()
    }

    private static func items(in list: LSSharedFileList) -> [LSSharedFileListItem] {
        var seed: UInt32 = 0
        guard let array = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() else { return [] }
        return (0..<CFArrayGetCount(array)).map { unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: LSSharedFileListItem.self) }
    }

    private static func resolvedPath(_ item: LSSharedFileListItem) -> String? {
        (LSSharedFileListItemCopyResolvedURL(item, 0, nil)?.takeRetainedValue() as URL?)?.standardizedFileURL.path
    }

    static func contains(_ url: URL) -> Bool {
        guard let list = list() else { return false }
        let target = url.standardizedFileURL.path
        return items(in: list).contains { resolvedPath($0) == target }
    }

    /// Adds `url` to the end of Favorites. Returns true if it's pinned afterwards.
    @discardableResult
    static func add(_ url: URL) -> Bool {
        guard let list = list() else { return false }
        if contains(url) { return true }
        guard let anchor = items(in: list).last else { return false }
        let item = LSSharedFileListInsertItemURL(list, anchor, url.lastPathComponent as CFString, nil, url as CFURL,
                                                 [:] as CFDictionary, [] as CFArray)
        let pinned = item != nil && contains(url)
        Log.write("sidebar", pinned ? "pinned \(path: url)" : "couldn't pin \(path: url)")
        return pinned
    }
}
