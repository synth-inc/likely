#!/bin/bash
# Bumps Likely's version in Info.plist.
#
#   scripts/bump-version.sh patch|minor|major   0.1.0 -> 0.1.1 / 0.2.0 / 1.0.0
#   scripts/bump-version.sh 1.2.3               set an explicit marketing version
#   scripts/bump-version.sh build               only bump the build number
#
# CFBundleVersion (the build number, Sparkle's sparkle:version) always goes up by one: Sparkle compares
# it to decide whether a release is newer, so it must increase with every release.
set -euo pipefail
cd "$(dirname "$0")/.."
PLIST=Info.plist
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }

SHORT=$(pb "Print :CFBundleShortVersionString")
BUILD=$(pb "Print :CFBundleVersion")
IFS=. read -r MAJOR MINOR PATCH <<<"$SHORT"
MAJOR=${MAJOR:-0}; MINOR=${MINOR:-0}; PATCH=${PATCH:-0}

case "${1:-}" in
    major) NEW="$((MAJOR + 1)).0.0" ;;
    minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    build) NEW="$SHORT" ;;
    [0-9]*.[0-9]*) NEW="$1" ;;
    *) echo "usage: $0 patch|minor|major|build|X.Y.Z"; exit 1 ;;
esac
NEW_BUILD=$((BUILD + 1))

pb "Set :CFBundleShortVersionString $NEW"
pb "Set :CFBundleVersion $NEW_BUILD"
echo "Likely $SHORT ($BUILD) -> $NEW ($NEW_BUILD)"
echo "Commit it: git commit -am \"Bump version to $NEW ($NEW_BUILD)\""
