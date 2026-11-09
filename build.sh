#!/bin/bash
# Builds Likely.app into ./build. Signs with an "Apple Development" identity so Accessibility /
# Screen Recording grants survive rebuilds (ad-hoc signatures change every build).
#
# Without a provisioning profile, the app has no keychain access group, so encryption of search
# history and test screenshots is off (docs/BUILDING.md, docs/PRIVACY.md). With one (LIKELY_PROFILE),
# the profile is embedded as Contents/embedded.provisionprofile and the app is signed with the
# entitlements scripts/provisioning.py makes from Likely.entitlements and the profile: encryption on.
#
# Env:
#   LIKELY_FREE=1          build the open-source edition without the license page.
#   LIKELY_SIGN_ID=...     signing identity: SHA-1 hash or name (CODESIGN_IDENTITY is the older name).
#                          Default: with a profile, the one identity the profile was made for; without,
#                          the first "Apple Development" identity (pin one if you have several).
#   LIKELY_PROFILE=...     a macOS provisioning profile (App Development or Developer ID) for an
#                          explicit App ID matching the bundle id: turns encryption on.
#   LIKELY_BUNDLE_ID=...   bundle id (default: inc.synth.likely). Set it to your own App ID's.
#   LIKELY_TEAM_ID=...     your team id; checked against the profile and the signing identity.
#   BUILD_DIR=...          output folder (default: build). scripts/release.sh uses build/release so it
#                          never replaces a dev build/Likely.app that may be running.
#   LIKELY_DISTRIBUTION=1  sign for distribution: hardened runtime, secure timestamp, a Developer ID
#                          identity and LIKELY_PROFILE required (scripts/release.sh sets this).
set -euo pipefail
cd "$(dirname "$0")"

# LIKELY_FREE=1 ./build.sh builds the open-source edition without the license page.
# Builds are dev builds (LIKELY_DEV: devLicenseOverride, Settings → Debug) unless LIKELY_DISTRIBUTION=1,
# which scripts/release.sh sets.
FLAGS=()
[ "${LIKELY_FREE:-}" = "1" ] && FLAGS+=(-Xswiftc -DLIKELY_FREE)
DEV_BUILD=true
[ "${LIKELY_DISTRIBUTION:-}" = "1" ] && DEV_BUILD=false
[ "$DEV_BUILD" = true ] && FLAGS+=(-Xswiftc -DLIKELY_DEV)
swift build -c release ${FLAGS[@]+"${FLAGS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path)"
# Signing identity and, with a profile, the entitlements: checked before the old app is replaced.
BUNDLE_ID="${LIKELY_BUNDLE_ID:-inc.synth.likely}"
IDENTITY="${LIKELY_SIGN_ID:-${CODESIGN_IDENTITY:-}}"
OPTS=()
APP_OPTS=()
if [ "${LIKELY_DISTRIBUTION:-}" = "1" ]; then
    [ -n "${LIKELY_PROFILE:-}" ] || { echo "LIKELY_DISTRIBUTION=1 needs LIKELY_PROFILE (releases are always encrypted)"; exit 1; }
    OPTS=(--options runtime --timestamp)
fi
if [ -n "${LIKELY_PROFILE:-}" ]; then
    # Checks the profile against the bundle id, team and identity, picks the identity if none was
    # given, and writes the entitlements to sign with (see scripts/provisioning.py).
    [ -f "$LIKELY_PROFILE" ] || { echo "LIKELY_PROFILE: no such file: $LIKELY_PROFILE"; exit 1; }
    mkdir -p "${BUILD_DIR:-build}"
    ENTITLEMENTS="${BUILD_DIR:-build}/Likely.entitlements.generated"
    PROVISIONING_ARGS=(--profile "$LIKELY_PROFILE" --bundle-id "$BUNDLE_ID" --template Likely.entitlements
                       --out "$ENTITLEMENTS" --identity "$IDENTITY" --team "${LIKELY_TEAM_ID:-}")
    [ "${LIKELY_DISTRIBUTION:-}" = "1" ] && PROVISIONING_ARGS+=(--developer-id)
    IDENTITY="$(python3 -I scripts/provisioning.py "${PROVISIONING_ARGS[@]}" | tail -1)"
    APP_OPTS=(--entitlements "$ENTITLEMENTS")
    echo "Encryption: on (provisioning profile embedded)"
else
    if [ -z "$IDENTITY" ]; then
        DEV_IDENTITIES="$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2}')"
        IDENTITY="$(echo "$DEV_IDENTITIES" | head -1)"
        if [ "$(echo "$DEV_IDENTITIES" | grep -c .)" -gt 1 ]; then
            echo "Several Apple Development identities; using $IDENTITY. Pin one with LIKELY_SIGN_ID so permissions stick."
        fi
    fi
    if [ -z "$IDENTITY" ]; then
        echo "No Apple Development identity found; signing ad-hoc (permissions will reset on each rebuild)"
        IDENTITY="-"
    fi
    echo "Encryption: off (no LIKELY_PROFILE; see docs/BUILDING.md)"
fi
[ "${LIKELY_DISTRIBUTION:-}" = "1" ] && [ "$IDENTITY" = "-" ] && { echo "LIKELY_DISTRIBUTION=1 needs a real signing identity"; exit 1; }
APP="${BUILD_DIR:-build}/Likely.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Likely" "$APP/Contents/MacOS/Likely"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
# The profile goes in before signing, so the signature seals it.
[ -n "${LIKELY_PROFILE:-}" ] && cp "$LIKELY_PROFILE" "$APP/Contents/embedded.provisionprofile"
# Free and dev builds never use the update feed: no feed, no key, no scheduled checks (Updater stays
# off). Otherwise Sparkle would offer to replace a dev build with the latest release.
if [ "${LIKELY_FREE:-}" = "1" ] || [ "$DEV_BUILD" = true ]; then
    for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
    done
fi
# Bundled resources, e.g. Resources/likely-demo.mp4 for the onboarding demo video.
if compgen -G "Resources/*" > /dev/null; then cp -R Resources/. "$APP/Contents/Resources/"; fi
# Sparkle (auto-updates). The executable finds it through its @executable_path/../Frameworks rpath.
# ditto keeps the framework's Versions/Current symlinks intact.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -f "$APP/Contents/Resources/README.md"
# Dev builds also get the candidate menu bar glyphs (Settings → Debug) and the public eval suite
# (Settings → Evals → Run Suite → Public fixtures; `--eval fixtures`). Release builds have no evals UI.
if [ "$DEV_BUILD" = true ]; then
    cp -R ResourcesDev/. "$APP/Contents/Resources/"
    mkdir -p "$APP/Contents/Resources/evals"
    cp -R evals/fixtures "$APP/Contents/Resources/evals/"
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
