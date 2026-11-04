#!/bin/bash
# Bumps Likely's version in Info.plist.
#
#   scripts/bump-version.sh patch|minor|major   0.1.0 -> 0.1.1 / 0.2.0 / 1.0.0
#   scripts/bump-version.sh 1.2.3               set an explicit marketing version
#   scripts/bump-version.sh build               only bump the build number (only before the version
#                                               is released: release.sh tags vX.Y.Z, once per version)
#
# This script never tags; scripts/release.sh creates the vX.Y.Z tag when it publishes.
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

# Every release gets a new vX.Y.Z tag, so a version that's already tagged can't be released again.
git fetch -q --tags origin 2>/dev/null || true
if git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null; then
    echo "v$NEW is already released (tag v$NEW exists); use patch, minor, major or a new X.Y.Z"; exit 1
fi

pb "Set :CFBundleShortVersionString $NEW"
pb "Set :CFBundleVersion $NEW_BUILD"
echo "Likely $SHORT ($BUILD) -> $NEW ($NEW_BUILD)"
echo "Commit it: git commit -am \"Bump version to $NEW ($NEW_BUILD)\""
