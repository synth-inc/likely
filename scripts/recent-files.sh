#!/bin/bash
# Prints the files Likely would put in the Likely folder as recent files on this Mac, and how long
# the query took. Runs the real RecentFiles.swift and RecentFilesCore (unit tests: `swift test`).
# Usage: scripts/recent-files.sh [count] [-v]   (default 3; searches Desktop, Documents, Downloads, iCloud Drive)
#   -v also lists the files that were looked at and skipped, and why.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
let args = CommandLine.arguments.dropFirst()
let limit = args.first.flatMap { Int($0) } ?? 3
let verbose = args.contains("-v")
let home = FileManager.default.homeDirectoryForCurrentUser
let roots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs"]
    .map { home.appendingPathComponent($0) }
let likely = UserDefaults(suiteName: "inc.synth.likely")?.string(forKey: "likelyFolderPath") ?? home.appendingPathComponent("Likely").path
let excluded = [likely, home.appendingPathComponent("Library/Application Support/Likely").path]
for run in 1...3 {
    let result = RecentFiles.find(limit: limit, roots: roots, excluding: excluded, home: home.path, sameVolumeAs: likely)
    print("run \(run): \(result.files.count) via \(result.source) in \(result.milliseconds) ms")
    guard run == 3 else { continue }
    result.files.forEach { print("  \($0.added)  \($0.path)") }
    if verbose {
        print("looked at:")
        result.verdicts.forEach { print("  \($0.verdict.padding(toLength: 28, withPad: " ", startingAt: 0)) \($0.path)") }
    }
}
SWIFT
swiftc -O "$ROOT/Sources/Likely/SensitivePaths.swift" "$ROOT/Sources/Likely/RecentFiles.swift" \
    "$ROOT"/Sources/RecentFilesCore/*.swift "$TMP/main.swift" -o "$TMP/recent-files"
"$TMP/recent-files" "$@"
