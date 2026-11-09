#!/bin/bash
# Cuts a Likely release: Developer ID build -> Likely.dmg -> notarize + staple -> Sparkle EdDSA
# signature -> GitHub Release vX.Y.Z with Likely.dmg -> new item in docs/appcast.xml (GitHub Pages).
#
#   scripts/bump-version.sh patch && git commit -am "Bump version"   # first, on a clean tree
#   scripts/release.sh [--dry-run] [--skip-notarize] [--notes "text"]
#
#   --dry-run        build, sign, make the DMG, notarize and write the appcast to build/release only:
#                    no tag, no GitHub Release, no appcast commit.
#   --skip-notarize  skip notarization/stapling (only allowed with --dry-run).
#   --notes "..."    release notes for the GitHub Release and the Sparkle update window.
#
# Version and build number come from Info.plist (CFBundleShortVersionString / CFBundleVersion).
#
# Needs:
#   - "Developer ID Application: Synthetic Exploration, Inc (TYC9PKBMB6)" in the login Keychain
#     (override with SIGN_ID).
#   - LIKELY_PROFILE: the "Likely Developer ID" provisioning profile (Developer ID, App ID
#     TYC9PKBMB6.inc.synth.likely, made with that certificate). It's embedded in the app and gives it
#     the keychain access group that turns encryption on (docs/BUILDING.md). Checked before building:
#     App ID = bundle id, same team as SIGN_ID, macOS, at least a year left (fails otherwise unless
#     LIKELY_ALLOW_SHORT_PROFILE=1; warns with less than two years left).
#   - Notarization credentials, same as the other Synth apps' build_and_notarize.sh:
#     NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER_ID (App Store Connect API key), or
#     NOTARY_PROFILE=<notarytool keychain profile>.
#   - The Sparkle EdDSA private key in the login Keychain, account "likely"
#     (created with `generate_keys --account likely`).
#   - gh authenticated with push access to synth-inc/likely.
#   - The update feed is docs/appcast.xml in this repo, served by GitHub Pages at $FEED_URL
#     (https://synth-inc.github.io/likely/appcast.xml). The script commits it to main and pushes;
#     Sparkle clients see the release once Pages has redeployed (about a minute).
#   - Bridge for 0.1.0 installs: Likely 0.1.0 checks the old feed on onit-server
#     (onit-server-v2-...herokuapp.com/likely/appcast.xml). Set LEGACY_FEED_DIR to an onit-server checkout
#     (use a worktree, e.g. ~/Apps/onit-server-likely) to also write the appcast there, then deploy it.
#     Keep doing this until 0.1.0 installs have updated; the first release with the new feed URL moves them over.
set -euo pipefail

# Releases are the paid edition, built without dev-only switches, whatever the calling shell has set.
if [ -n "${LIKELY_FREE:-}" ]; then
    echo "LIKELY_FREE is set; releases are the paid build. Run without it (unset LIKELY_FREE)."; exit 1
fi
if [ -n "${LIKELY_DEV:-}" ]; then
    echo "LIKELY_DEV is set; releases never include dev-only features. Run without it (unset LIKELY_DEV)."; exit 1
fi

APP_NAME="Likely"
GH_REPO="synth-inc/likely"
SPARKLE_ACCOUNT="likely"
SIGN_ID="${SIGN_ID:-Developer ID Application: Synthetic Exploration, Inc (TYC9PKBMB6)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/release"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$APP_NAME.dmg"
APPCAST_SRC="$ROOT/docs/appcast.xml"
LEGACY_FEED_DIR="${LEGACY_FEED_DIR:-}"
LEGACY_APPCAST_REL="public/likely/appcast.xml"
FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" Info.plist)

DRY_RUN=false
SKIP_NOTARIZE=false
NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --notes) NOTES="$2"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done
[ "$SKIP_NOTARIZE" = true ] && [ "$DRY_RUN" = false ] && { echo "--skip-notarize requires --dry-run"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
TAG="v$VERSION"
DOWNLOAD_URL="https://github.com/$GH_REPO/releases/download/$TAG/$APP_NAME.dmg"
echo "==> $APP_NAME $VERSION (build $BUILD), tag $TAG$([ "$DRY_RUN" = true ] && echo ", DRY RUN")"

# ---------------------------------------------------------------- preflight
SPARKLE_BIN="${SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"
[ -x "$SPARKLE_BIN/sign_update" ] || swift package resolve >/dev/null
[ -x "$SPARKLE_BIN/sign_update" ] || { echo "sign_update not found (set SPARKLE_BIN)"; exit 1; }
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p >/dev/null 2>&1 ||
    { echo "No Sparkle key for account '$SPARKLE_ACCOUNT' in the Keychain"; exit 1; }
PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)
[ "$PUBLIC_KEY" = "$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Info.plist)" ] ||
    { echo "SUPublicEDKey in Info.plist doesn't match the Keychain key '$SPARKLE_ACCOUNT'"; exit 1; }
security find-identity -v -p codesigning | grep -qF "$SIGN_ID" || { echo "Signing identity not found: $SIGN_ID"; exit 1; }
[ -n "${LIKELY_PROFILE:-}" ] || { echo "LIKELY_PROFILE isn't set: the Developer ID provisioning profile (see docs/BUILDING.md)"; exit 1; }
[ -f "$LIKELY_PROFILE" ] || { echo "LIKELY_PROFILE: no such file: $LIKELY_PROFILE"; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
# Fails early on a profile that doesn't fit; build.sh runs the same check again when signing.
PREFLIGHT_ENTITLEMENTS=$(mktemp)
python3 -I scripts/provisioning.py --profile "$LIKELY_PROFILE" --bundle-id "$BUNDLE_ID" --template Likely.entitlements \
    --out "$PREFLIGHT_ENTITLEMENTS" --identity "$SIGN_ID" --developer-id >/dev/null
TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.team-identifier" "$PREFLIGHT_ENTITLEMENTS")
rm -f "$PREFLIGHT_ENTITLEMENTS"

if [ "$SKIP_NOTARIZE" = false ]; then
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
        NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    else
        echo "Notarization credentials missing: set NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID or NOTARY_PROFILE"
        exit 1
    fi
fi

if [ "$DRY_RUN" = false ]; then
    # Publishing only from main, exactly as committed (--dry-run works on any branch).
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    [ "$BRANCH" = "main" ] || { echo "Releases are published from main (on $BRANCH). Use --dry-run to test elsewhere."; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "Working tree not clean; commit the version bump first"; exit 1; }
    # ...and exactly what's on GitHub's main: nothing unpushed, nothing missing.
    git fetch -q origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] ||
        { echo "HEAD isn't origin/main; push (or pull) main first"; exit 1; }
    git fetch -q --tags origin
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "Tag $TAG already exists; run scripts/bump-version.sh patch"; exit 1; }
    gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1 && { echo "Release $TAG already exists"; exit 1; }
    if [ -n "$LEGACY_FEED_DIR" ]; then
        [ -d "$LEGACY_FEED_DIR/public" ] || { echo "LEGACY_FEED_DIR has no public/ folder: $LEGACY_FEED_DIR"; exit 1; }
    else
        echo "Note: LEGACY_FEED_DIR isn't set, so 0.1.0 installs (old onit-server feed) won't see this release."
    fi
    if [ -f "$APPCAST_SRC" ] && grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST_SRC"; then
        echo "Build $BUILD is already in the appcast; run scripts/bump-version.sh"; exit 1
    fi
fi

# ---------------------------------------------------------------- build + sign
echo "==> Building and signing with $SIGN_ID"
rm -rf "$OUT"
mkdir -p "$OUT"
BUILD_DIR="$OUT" LIKELY_SIGN_ID="$SIGN_ID" LIKELY_PROFILE="$LIKELY_PROFILE" LIKELY_BUNDLE_ID="$BUNDLE_ID" \
    LIKELY_TEAM_ID="$TEAM_ID" LIKELY_DISTRIBUTION=1 ./build.sh
codesign --verify --deep --strict --verbose=2 "$APP"
scripts/check-signature.sh "$APP" "$TEAM_ID" "$BUNDLE_ID" "$LIKELY_PROFILE"
# build.sh only compiles dev features (LIKELY_DEV) when LIKELY_DISTRIBUTION isn't set; make sure.
if grep -q "devLicenseOverride" "$APP/Contents/MacOS/$APP_NAME" || [ -d "$APP/Contents/Resources/MenuBarGlyphs" ]; then
    echo "The release build contains dev-only features"; exit 1
fi

# ---------------------------------------------------------------- DMG
echo "==> Creating $DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# ---------------------------------------------------------------- notarize + staple
if [ "$SKIP_NOTARIZE" = false ]; then
    echo "==> Notarizing (this takes a few minutes)"
    NOTARY_OUT=$(xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait 2>&1) || true
    echo "$NOTARY_OUT"
    if ! echo "$NOTARY_OUT" | grep -q "status: Accepted"; then
        SUB_ID=$(echo "$NOTARY_OUT" | awk '/^ *id:/ {print $2; exit}')
        [ -n "$SUB_ID" ] && xcrun notarytool log "$SUB_ID" "${NOTARY_AUTH[@]}" || true
        echo "Notarization failed"; exit 1
    fi
    for _ in 1 2 3 4 5 6 7 8 9; do
        xcrun stapler staple "$DMG" && break
        echo "Ticket not available yet, retrying in 10s"; sleep 10
    done
    xcrun stapler validate "$DMG"
    # Gatekeeper check of the app as a user gets it from the DMG.
    MNT=$(mktemp -d)
    hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
    spctl -a -vv --type execute "$MNT/$APP_NAME.app" || { hdiutil detach "$MNT" >/dev/null; echo "spctl rejected the app"; exit 1; }
    hdiutil detach "$MNT" >/dev/null
fi

# ---------------------------------------------------------------- Sparkle signature + appcast item
echo "==> Signing the update for Sparkle"
# Prints: sparkle:edSignature="..." length="..."
ENCLOSURE_ATTRS=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")
ED_SIGNATURE=$(echo "$ENCLOSURE_ATTRS" | sed -E 's/.*edSignature="([^"]+)".*/\1/')
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$DMG" "$ED_SIGNATURE" ||
    { echo "Sparkle signature doesn't verify"; exit 1; }
APPCAST_OUT="$OUT/appcast.xml"
if [ -f "$APPCAST_SRC" ]; then
    cp "$APPCAST_SRC" "$APPCAST_OUT"
fi
python3 "$ROOT/scripts/appcast_add_item.py" "$APPCAST_OUT" \
    --version "$VERSION" --build "$BUILD" --url "$DOWNLOAD_URL" --enclosure "$ENCLOSURE_ATTRS" \
    --min-system "$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist)" \
    --release-page "https://github.com/$GH_REPO/releases/tag/$TAG" --notes "$NOTES"

if [ "$DRY_RUN" = true ]; then
    echo
    echo "Dry run done. Nothing was published."
    echo "  App:     $APP"
    echo "  DMG:     $DMG"
    echo "  Appcast: $APPCAST_OUT"
    exit 0
fi

# ---------------------------------------------------------------- publish
echo "==> Tagging $TAG and creating the GitHub Release"
git tag -a "$TAG" -m "$APP_NAME $VERSION (build $BUILD)"
git push origin "$TAG"
NOTES_ARGS=(--generate-notes)
[ -n "$NOTES" ] && NOTES_ARGS=(--notes "$NOTES")
# The asset is named exactly Likely.dmg so .../releases/latest/download/Likely.dmg always works.
gh release create "$TAG" "$DMG#$APP_NAME.dmg" --repo "$GH_REPO" --verify-tag \
    --title "$APP_NAME $VERSION" "${NOTES_ARGS[@]}"

echo "==> Publishing the appcast (docs/appcast.xml on GitHub Pages)"
cp "$APPCAST_OUT" "$APPCAST_SRC"
git add docs/appcast.xml
git commit -q -m "Likely $VERSION appcast"
if ! git push -q origin HEAD:main; then
    echo "Couldn't push the appcast to main. Push this commit (or open a PR) yourself: $(git rev-parse --short HEAD)"
fi
if [ -n "$LEGACY_FEED_DIR" ]; then
    echo "==> Bridge: updating $LEGACY_FEED_DIR/$LEGACY_APPCAST_REL for 0.1.0 installs"
    mkdir -p "$(dirname "$LEGACY_FEED_DIR/$LEGACY_APPCAST_REL")"
    cp "$APPCAST_OUT" "$LEGACY_FEED_DIR/$LEGACY_APPCAST_REL"
    echo "  In $LEGACY_FEED_DIR: git add $LEGACY_APPCAST_REL && git commit -m \"Likely $VERSION appcast\" && git push   # then deploy"
fi
echo
echo "Released $TAG: https://github.com/$GH_REPO/releases/tag/$TAG"
echo "Sparkle clients see it once GitHub Pages has redeployed. Check: curl -s $FEED_URL | head"
