#!/bin/bash
# Checks SensitivePaths (which FILE: suggestions Likely refuses to copy). No test target in this
# package, so this runs the real source file plus a few cases with the Swift interpreter.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat "$ROOT/Sources/Likely/SensitivePaths.swift" > "$TMP/main.swift"
cat >> "$TMP/main.swift" <<'SWIFT'

let home = "/Users/alex"
let refused = [
    "/Users/alex/.ssh/id_ed25519", "/Users/alex/.aws/credentials", "/Users/alex/.config/gh/hosts.yml",
    "/Users/alex/.gnupg/private-keys-v1.d/x.key", "/Users/alex/project/.env", "/Users/alex/project/.env.local",
    "/Users/alex/project/.git/config", "/Users/alex/Library/Keychains/login.keychain-db",
    "/Users/alex/Library/Application Support/Google/Chrome/Default/Cookies", "/Users/alex/Library/Messages/chat.db",
    "/Users/alex/library/preferences/x.plist", "/etc/passwd", "/private/etc/master.passwd", "/private/var/db/x",
    "/var/root/x", "/tmp/x.pdf", "/Library/Keychains/System.keychain", "/Volumes/USB/backup/login.keychain-db",
    "/Users/alex/Documents/../.ssh/id_rsa",
]
let allowed = [
    "/Users/alex/Documents/Invoice March.pdf", "/Users/alex/Desktop/Screenshot 2026-11-04.png",
    "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/Taxes/2025.pdf",
    "/Users/alex/Library/CloudStorage/GoogleDrive-alex@example.com/My Drive/deck.key",
    "/Volumes/USB/photos/IMG_0001.HEIC", "/Users/alex/Downloads/report.v2.pdf", "/Users/Shared/notes.txt",
]
var failures = 0
for path in refused where SensitivePaths.refusalReason(for: path, home: home) == nil {
    print("FAIL (should refuse): \(path)"); failures += 1
}
for path in allowed {
    if let reason = SensitivePaths.refusalReason(for: path, home: home) {
        print("FAIL (should allow): \(path) [\(reason)]"); failures += 1
    }
}
print(failures == 0 ? "OK: \(refused.count) refused, \(allowed.count) allowed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
SWIFT
swift "$TMP/main.swift"
