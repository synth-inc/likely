#!/bin/bash
# Prints the files Likely would put in the Likely folder as recent files on this Mac, and how long
# the query took. Runs the real RecentFiles.swift (no test target in this package).
# Usage: scripts/recent-files.sh [count]   (default 3; searches Desktop, Documents, Downloads, iCloud Drive)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
let limit = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 3 : 3
let home = FileManager.default.homeDirectoryForCurrentUser
let roots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs"]
    .map { home.appendingPathComponent($0) }
let excluded = [home.appendingPathComponent("Likely").path, home.appendingPathComponent("Library/Application Support/Likely").path]
for run in 1...3 {
    let result = RecentFiles.find(limit: limit, roots: roots, excluding: excluded, home: home.path)
    print("run \(run): \(result.files.count) via \(result.source) in \(result.milliseconds) ms")
    if run == 3 { result.files.forEach { print("  \($0.added)  \($0.path)") } }
}
SWIFT
swiftc -O "$ROOT/Sources/Likely/SensitivePaths.swift" "$ROOT/Sources/Likely/RecentFiles.swift" "$TMP/main.swift" -o "$TMP/recent-files"
"$TMP/recent-files" "${1:-3}"
