#!/usr/bin/env python3
"""Checks a macOS provisioning profile for Likely and writes the entitlements to sign with.

Used by build.sh when LIKELY_PROFILE is set (and so by scripts/release.sh, which requires it). See
docs/BUILDING.md.

  scripts/provisioning.py --profile P --bundle-id B --template Likely.entitlements --out OUT
                          [--identity ID] [--team T] [--developer-id]

Checks, failing with a message on any problem:
  - the profile is for macOS (Platform OSX) and not expired (warns when it expires within 60 days);
  - its App ID is exactly <team>.<bundle id> (an explicit App ID);
  - its team matches --team (LIKELY_TEAM_ID) when given, and the signing identity's team;
  - the signing identity's certificate is one the profile lists (otherwise macOS refuses to launch
    the app); with --developer-id, it must be a "Developer ID Application" certificate;
  - for development profiles, warns if this Mac isn't one of its devices.

Signing identity: --identity (a SHA-1 hash, a full name, or a unique part of one), else the one
identity in the login keychain whose certificate the profile lists. Prints its SHA-1 on the last
line of stdout for build.sh to sign with.

The entitlements come from the template (Likely.entitlements, with $(TeamID) and $(BundleID)) and
are checked against the profile's own Entitlements: the application and team identifiers must be the
profile's, and each keychain access group must be a concrete group the profile allows (it allows
"<team>.*").
"""
import argparse
import base64
import datetime
import fnmatch
import hashlib
import plistlib
import re
import subprocess
import sys

APP_ID_KEY = "com.apple.application-identifier"
TEAM_KEY = "com.apple.developer.team-identifier"
GROUPS_KEY = "keychain-access-groups"
WARN_DAYS = 60


def fail(message):
    print(f"provisioning: {message}", file=sys.stderr)
    sys.exit(1)


def warn(message):
    print(f"provisioning: warning: {message}", file=sys.stderr)


def run(args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def decode_profile(path):
    try:
        data = run(["security", "cms", "-D", "-i", path])
    except subprocess.CalledProcessError as e:
        fail(f"can't read the provisioning profile {path}: {e.stderr.decode(errors='replace').strip()}")
    except FileNotFoundError:
        fail("`security` not found")
    return plistlib.loads(data)


def codesigning_identities():
    """[(sha1, name)] of valid code-signing identities."""
    out = run(["security", "find-identity", "-v", "-p", "codesigning"]).decode()
    return [(m.group(1).upper(), m.group(2)) for m in re.finditer(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.+)"\s*$', out, re.M)]


def certificates_by_sha1():
    """{sha1: DER} of every certificate in the keychain search list."""
    out = run(["security", "find-certificate", "-a", "-Z", "-p"]).decode(errors="replace")
    certs = {}
    for m in re.finditer(r"SHA-1 hash: ([0-9A-Fa-f]{40}).*?-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", out, re.S):
        certs[m.group(1).upper()] = base64.b64decode("".join(m.group(2).split()))
    return certs


def certificate_team(der):
    """The team id: the certificate subject's organizational unit."""
    pem = b"-----BEGIN CERTIFICATE-----\n" + base64.encodebytes(der) + b"-----END CERTIFICATE-----\n"
    out = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "multiline"],
                         input=pem, capture_output=True).stdout.decode(errors="replace")
    m = re.search(r"organizationalUnitName\s*=\s*([A-Z0-9]{10})", out) or re.search(r"OU\s*=\s*([A-Z0-9]{10})", out)
    return m.group(1) if m else None


def resolve_identity(wanted, profile_certs, identities, certs):
    """(sha1, name) to sign with."""
    if wanted:
        w = wanted.strip()
        matches = [i for i in identities if i[0] == w.upper()] or [i for i in identities if i[1] == w] \
            or [i for i in identities if w in i[1]]
        if not matches:
            fail(f"signing identity not found: {wanted}")
        if len(matches) > 1:
            fail(f"'{wanted}' matches {len(matches)} identities; set LIKELY_SIGN_ID to one SHA-1:\n"
                 + "\n".join(f"  {s}  {n}" for s, n in matches))
        return matches[0]
    in_profile = [i for i in identities if certs.get(i[0]) in profile_certs]
    if not in_profile:
        fail("none of your signing identities is in this provisioning profile. Install the certificate the "
             "profile was made with, or make a profile for one of your certificates.")
    if len(in_profile) > 1:
        fail("several of your identities are in this profile; pin one with LIKELY_SIGN_ID:\n"
             + "\n".join(f"  {s}  {n}" for s, n in in_profile))
    return in_profile[0]


def this_macs_provisioning_udid():
    try:
        out = run(["system_profiler", "SPHardwareDataType"]).decode(errors="replace")
    except Exception:
        return None
    m = re.search(r"Provisioning UDID:\s*(\S+)", out)
    return m.group(1) if m else None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--profile", required=True)
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--template", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--identity", default="")
    p.add_argument("--team", default="")
    p.add_argument("--developer-id", action="store_true", help="require a Developer ID Application identity")
    a = p.parse_args()

    profile = decode_profile(a.profile)
    name = profile.get("Name", "?")
    entitlements = profile.get("Entitlements", {})

    if "OSX" not in profile.get("Platform", []):
        fail(f"profile '{name}' isn't a macOS profile (Platform {profile.get('Platform')})")

    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime):
        fail(f"profile '{name}' has no expiration date")
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)  # plistlib dates are naive UTC
    if expires <= now:
        fail(f"profile '{name}' expired on {expires:%Y-%m-%d}")
    if expires - now < datetime.timedelta(days=WARN_DAYS):
        warn(f"profile '{name}' expires on {expires:%Y-%m-%d}, in {(expires - now).days} days: renew it soon")

    teams = profile.get("TeamIdentifier", [])
    if len(teams) != 1:
        fail(f"profile '{name}' has {len(teams)} teams")
    team = teams[0]
    if a.team and a.team != team:
        fail(f"profile '{name}' is for team {team}, not LIKELY_TEAM_ID={a.team}")
    if entitlements.get(TEAM_KEY, team) != team:
        fail(f"profile '{name}': team-identifier {entitlements.get(TEAM_KEY)} isn't its team {team}")

    app_id = entitlements.get(APP_ID_KEY)
    expected_app_id = f"{team}.{a.bundle_id}"
    if not app_id:
        fail(f"profile '{name}' has no {APP_ID_KEY}")
    if app_id != expected_app_id:
        hint = " (a wildcard App ID: register an explicit one for the bundle id)" if "*" in app_id else ""
        fail(f"profile '{name}' is for App ID {app_id}, but the app is {expected_app_id}{hint}")

    allowed_groups = entitlements.get(GROUPS_KEY, [])
    if not allowed_groups:
        fail(f"profile '{name}' allows no keychain access groups")

    profile_certs = set(bytes(c) for c in profile.get("DeveloperCertificates", []))
    identities = codesigning_identities()
    certs = certificates_by_sha1()
    sha1, identity_name = resolve_identity(a.identity, profile_certs, identities, certs)
    der = certs.get(sha1)
    if der is None:
        fail(f"can't find the certificate of {identity_name}")
    identity_team = certificate_team(der)
    if identity_team != team:
        fail(f"{identity_name} is team {identity_team}, the profile is team {team}")
    if der not in profile_certs:
        fail(f"profile '{name}' doesn't include the certificate of {identity_name} (macOS would refuse to "
             "launch the app). Use the identity the profile was made for (LIKELY_SIGN_ID), or a profile "
             "that includes this certificate.")
    if a.developer_id and not identity_name.startswith("Developer ID Application:"):
        fail(f"releases are signed with a Developer ID Application identity, not {identity_name}")

    devices = profile.get("ProvisionedDevices")
    if devices and not profile.get("ProvisionsAllDevices"):
        udid = this_macs_provisioning_udid()
        if udid and udid not in devices:
            warn(f"this Mac ({udid}) isn't a device in profile '{name}': the app won't launch here")

    # The entitlements to sign with: the template, filled in, checked against the profile.
    with open(a.template, "rb") as f:
        text = f.read().decode()
    text = text.replace("$(TeamID)", team).replace("$(BundleID)", a.bundle_id)
    if "$(" in text:
        fail(f"{a.template} has a variable this script doesn't fill in")
    signed = plistlib.loads(text.encode())
    if signed.get(APP_ID_KEY) != app_id:
        fail(f"{APP_ID_KEY} would be {signed.get(APP_ID_KEY)}, the profile says {app_id}")
    if signed.get(TEAM_KEY) != team:
        fail(f"{TEAM_KEY} would be {signed.get(TEAM_KEY)}, the profile says {team}")
    groups = signed.get(GROUPS_KEY, [])
    if not groups:
        fail(f"{a.template} has no {GROUPS_KEY}")
    for g in groups:
        if "*" in g:
            fail(f"keychain access group {g} must be concrete")
        if not any(fnmatch.fnmatchcase(g, allowed) for allowed in allowed_groups):
            fail(f"keychain access group {g} isn't allowed by profile '{name}' ({', '.join(allowed_groups)})")
    with open(a.out, "wb") as f:
        plistlib.dump(signed, f)

    print(f"provisioning: profile '{name}' (team {team}, App ID {app_id}, expires {expires:%Y-%m-%d}), "
          f"signing as {identity_name}, keychain group {', '.join(groups)}", file=sys.stderr)
    print(sha1)


if __name__ == "__main__":
    main()
