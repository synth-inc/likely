#!/bin/bash
# Checks a signed Likely.app has what encryption needs (scripts/release.sh runs it after signing):
# the embedded provisioning profile, the hardened runtime, and the entitlements with the concrete
# keychain access group. See docs/BUILDING.md.
#
#   scripts/check-signature.sh <Likely.app> <team id> <bundle id> [<profile it should embed>]
set -euo pipefail
APP="$1"; TEAM="$2"; BUNDLE_ID="$3"; PROFILE="${4:-}"
fail() { echo "check-signature: $*"; exit 1; }

EMBEDDED="$APP/Contents/embedded.provisionprofile"
[ -f "$EMBEDDED" ] || fail "no Contents/embedded.provisionprofile"
[ -z "$PROFILE" ] || cmp -s "$EMBEDDED" "$PROFILE" || fail "the embedded profile isn't $PROFILE"

INFO=$(codesign -dvvv "$APP" 2>&1)
echo "$INFO" | grep -q "^TeamIdentifier=$TEAM\$" || fail "not signed by team $TEAM"
echo "$INFO" | grep -q "^Identifier=$BUNDLE_ID\$" || fail "signing identifier isn't $BUNDLE_ID"
echo "$INFO" | grep -Eq "flags=0x[0-9a-f]*\(.*runtime.*\)" || fail "no hardened runtime"

ENTITLEMENTS=$(mktemp)
trap 'rm -f "$ENTITLEMENTS"' EXIT
codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$ENTITLEMENTS"
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$ENTITLEMENTS" 2>/dev/null || true; }
[ "$(value com.apple.application-identifier)" = "$TEAM.$BUNDLE_ID" ] || fail "application-identifier isn't $TEAM.$BUNDLE_ID"
[ "$(value com.apple.developer.team-identifier)" = "$TEAM" ] || fail "team-identifier isn't $TEAM"
[ "$(value keychain-access-groups:0)" = "$TEAM.inc.synth.likely" ] || fail "keychain-access-groups isn't [$TEAM.inc.synth.likely]"
echo "check-signature: OK (team $TEAM, $TEAM.$BUNDLE_ID, keychain group $TEAM.inc.synth.likely, profile embedded, hardened runtime)"
