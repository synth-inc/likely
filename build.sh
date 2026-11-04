#!/bin/bash
# Builds Likely.app into ./build. Signs with your first "Apple Development" identity so
# Accessibility / Screen Recording grants survive rebuilds (ad-hoc signatures change every build).
set -euo pipefail
cd "$(dirname "$0")"

# LIKELY_FREE=1 ./build.sh builds the open-source edition without the license page.
if [ "${LIKELY_FREE:-}" = "1" ]; then
    swift build -c release -Xswiftc -DLIKELY_FREE
else
    swift build -c release
fi
APP=build/Likely.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Likely "$APP/Contents/MacOS/Likely"
cp Info.plist "$APP/Contents/Info.plist"
# Bundled resources, e.g. Resources/likely-demo.mp4 for the onboarding demo video.
if compgen -G "Resources/*" > /dev/null; then cp -R Resources/. "$APP/Contents/Resources/"; fi

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "No Apple Development identity found; signing ad-hoc (permissions will reset on each rebuild)"
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
