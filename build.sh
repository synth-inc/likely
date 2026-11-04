#!/bin/bash
# Builds Likely.app into ./build. Signs with your first "Apple Development" identity so
# Accessibility / Screen Recording grants survive rebuilds (ad-hoc signatures change every build).
#
# Env:
#   LIKELY_FREE=1          build the open-source edition without the license page.
#   CODESIGN_IDENTITY=...  signing identity (default: first "Apple Development" identity).
#   BUILD_DIR=...          output folder (default: build). scripts/release.sh uses build/release so it
#                          never replaces a dev build/Likely.app that may be running.
#   LIKELY_DISTRIBUTION=1  sign for distribution: hardened runtime, secure timestamp and
#                          Likely.entitlements (scripts/release.sh sets this with a Developer ID identity).
set -euo pipefail
cd "$(dirname "$0")"

# LIKELY_FREE=1 ./build.sh builds the open-source edition without the license page.
if [ "${LIKELY_FREE:-}" = "1" ]; then
    swift build -c release -Xswiftc -DLIKELY_FREE
else
    swift build -c release
fi
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="${BUILD_DIR:-build}/Likely.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Likely" "$APP/Contents/MacOS/Likely"
cp Info.plist "$APP/Contents/Info.plist"
# Bundled resources, e.g. Resources/likely-demo.mp4 for the onboarding demo video.
if compgen -G "Resources/*" > /dev/null; then cp -R Resources/. "$APP/Contents/Resources/"; fi
# Sparkle (auto-updates). The executable finds it through its @executable_path/../Frameworks rpath.
# ditto keeps the framework's Versions/Current symlinks intact.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
    echo "No Apple Development identity found; signing ad-hoc (permissions will reset on each rebuild)"
    IDENTITY="-"
fi
OPTS=()
APP_OPTS=()
if [ "${LIKELY_DISTRIBUTION:-}" = "1" ]; then
    [ "$IDENTITY" = "-" ] && { echo "LIKELY_DISTRIBUTION=1 needs a real signing identity"; exit 1; }
    OPTS=(--options runtime --timestamp)
    APP_OPTS=(--entitlements Likely.entitlements)
fi
sign() { codesign --force --sign "$IDENTITY" ${OPTS[@]+"${OPTS[@]}"} "$@"; }

# Nested code first, inside out (Sparkle's documented order), then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign ${APP_OPTS[@]+"${APP_OPTS[@]}"} "$APP"
echo "Built $APP"
