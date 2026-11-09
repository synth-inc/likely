# Building Likely

## From source

You need macOS 14 or later, Xcode (or its command line tools) with Swift 5.9 or later, and ideally an Apple
Development signing identity (a free Apple ID in Xcode → Settings → Accounts gives you one).

```sh
./build.sh                  # → build/Likely.app, a dev build
LIKELY_FREE=1 ./build.sh    # the open-source edition, without the license page
open build/Likely.app
swift test                  # unit tests
```

`build.sh` signs with an Apple Development identity so Accessibility and Screen Recording grants
survive rebuilds (an ad-hoc signature changes every build, and macOS then asks again). If you have
more than one, pin one with `LIKELY_SIGN_ID` (its SHA-1 from `security find-identity -v -p codesigning`,
or its full name). Otherwise the first one is used, and which one that is can change.

Builds from `./build.sh` are dev builds: they also have the Debug tab, `devLicenseOverride`, and the developer options of
`--eval` (public fixtures, any cases file, `--agent-path`, `--prompt-file`; see [EVALS.md](EVALS.md)).

## Encryption needs a provisioning profile

Likely encrypts your search history and the screenshots saved with tests with a key it keeps in the
**data-protection keychain**, in an access group of its own (`<team id>.inc.synth.likely`). Only apps
signed by the same team with that group in their `keychain-access-groups` entitlement can read the
key, and macOS never offers it to other apps. macOS only lets an app have that entitlement when a
**provisioning profile** embedded in the app allows it (otherwise it refuses to launch the app).

So a build without a profile has no encryption. That is the default for `./build.sh`. It keeps
history and test screenshots in plaintext, with Likely's other protections: owner-only files, the
agents' sandboxes can't read them, and they're kept out of Spotlight (see [PRIVACY.md](PRIVACY.md)).
Settings → History shows "Encryption: off in this build (no provisioning profile)".

There is deliberately no fallback. A key file next to the data would protect nothing, and the login
keychain shows "Likely wants to use your confidential information" prompts whenever the signature
changes, which happens on every dev rebuild.

Official releases are built with a profile and always encrypt.

## Turning encryption on with your own Apple team

You need a paid Apple Developer Program membership (profiles can't be made with a free account).

1. **Register an App ID.** In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
   → Identifiers → +, choose App IDs → App, platform macOS, and make it **explicit**. Use a bundle id
   of your own, for example `com.example.likely`. `inc.synth.likely` is taken by the official app. No
   capabilities are needed: the keychain access groups come with every profile.
2. **Make a profile.** Profiles → +, then either:
   - **macOS App Development**: for your own Mac. Choose the App ID, your Apple Development
     certificate, and the Mac you'll run it on (register it under Devices; its Provisioning UDID is in
     System Information → Hardware). Or
   - **Developer ID**: if you sign with a Developer ID Application certificate. It works on any Mac.
   Download the `.provisionprofile`.
3. **Build with it:**

   ```sh
   LIKELY_PROFILE=~/path/to/Likely_Dev.provisionprofile \
   LIKELY_BUNDLE_ID=com.example.likely \
   LIKELY_TEAM_ID=ABCDE12345 \
   LIKELY_SIGN_ID="Apple Development: Your Name (XXXXXXXXXX)" \
   ./build.sh
   ```

   `build.sh` checks the profile before building the app:
   - it's for macOS;
   - it isn't expired (and warns within 60 days of expiry; see Renewing the profile for releases);
   - its App ID is exactly `<team>.<LIKELY_BUNDLE_ID>`;
   - its team is `LIKELY_TEAM_ID` and the signing identity's team;
   - it includes the signing identity's certificate;
   - for a development profile, it includes this Mac.

   Then it embeds the profile as `Contents/embedded.provisionprofile` and signs with entitlements
   generated from [`Likely.entitlements`](../Likely.entitlements) and the profile. Without
   `LIKELY_SIGN_ID`, it uses the one identity the profile was made for. It prints
   `Encryption: on (provisioning profile embedded)`.

| Variable | Meaning |
| --- | --- |
| `LIKELY_PROFILE` | The `.provisionprofile`. Without it, encryption is off and nothing below applies. |
| `LIKELY_BUNDLE_ID` | Your App ID's bundle id (default `inc.synth.likely`). |
| `LIKELY_TEAM_ID` | Your team id, checked against the profile (optional). |
| `LIKELY_SIGN_ID` | The signing identity: SHA-1 or name (optional with a profile). |

To check a build: `codesign -d --entitlements - build/Likely.app` should list
`com.apple.application-identifier`, `com.apple.developer.team-identifier` and
`keychain-access-groups` = `<team>.inc.synth.likely`, and Settings → History should say
"Encryption: on".

A different bundle id is a different app to macOS. It needs its own Accessibility and Screen
Recording grants, and has its own settings.

### Codesign and variables

`codesign` doesn't expand `$(TeamID)`-style variables the way Xcode does, so `Likely.entitlements`
is a template. `scripts/provisioning.py` fills in the team and bundle id at sign time. It also checks
the result against the profile's own `Entitlements` (from `security cms -D -i <profile>`):
- the application and team identifiers are the profile's;
- the access group is concrete and within what the profile allows (`<team>.*`).

The app reads its entitlements at runtime (`SecTaskCopyValueForEntitlement`) to find the access
group, so nothing team-specific is compiled in.

### Switching between builds

History lives in two files, so builds with and without encryption never mix them:
- `History/history.enc.jsonl` is encrypted;
- `History/history.jsonl` is plaintext.

A build without encryption leaves `history.enc.jsonl` alone. Settings → History then says "History
is encrypted by another build of Likely", and the build keeps its own plaintext history. A build with
encryption encrypts plaintext history and test screenshots on launch and deletes the plaintext.
Builds of the same team share the key. A build of another team has its own key, and can't read the
other team's history lines, which are kept as they are. Likely never wipes data it can't read, and
never makes a new key over one it can't read.

## Releases (maintainers)

`scripts/release.sh` builds, signs, notarizes and publishes a release (see the script's header). It
requires `LIKELY_PROFILE`, the "Likely Developer ID" profile:
- Developer ID;
- App ID `TYC9PKBMB6.inc.synth.likely`;
- made with the Developer ID Application certificate.

Before building, it checks the profile like `build.sh` does, and also requires a Developer ID
identity. Then it builds with `LIKELY_DISTRIBUTION=1`, which embeds the profile and signs with the
generated entitlements, the hardened runtime and a secure timestamp. After signing,
`scripts/check-signature.sh` checks the app:
- the embedded profile is `LIKELY_PROFILE`;
- team and identifier are right;
- it has the hardened runtime;
- `codesign -d --entitlements -` shows the application identifier, the team identifier and the
  concrete keychain access group.

A release can't be built without a profile.

### Renewing the profile

A release embeds the profile, and an app whose embedded profile has expired may stop launching.
People keep running old versions for a long time, so a release
must have plenty left: with `--developer-id` (`scripts/release.sh`), `scripts/provisioning.py`
- fails when the profile has less than 365 days left (set `LIKELY_ALLOW_SHORT_PROFILE=1` to build
  anyway, for example for an urgent fix while the renewal is in progress);
- warns when it has less than two years left.

Developer ID profiles are issued for up to 18 years, so this rarely comes up. The current "Likely
Developer ID" profile expires in 2044. To renew:
1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/profiles/list),
   open the profile and click **Edit**, then **Save** (or make a new Developer ID profile for the App ID
   `TYC9PKBMB6.inc.synth.likely`). Choose the Developer ID Application certificate releases are signed
   with. If that certificate itself expires sooner, renew it first: a profile can't outlive it.
2. Download it to the same path as `LIKELY_PROFILE` (or point `LIKELY_PROFILE` at the new file).
3. Run `scripts/provisioning.py --profile "$LIKELY_PROFILE" --bundle-id inc.synth.likely --template Likely.entitlements --out /tmp/e.plist --developer-id`
   and check the expiry date it prints.
4. Ship a release with it. Versions already out keep the profile they embedded, so renew well before
   the old one expires, to give people time to update.

Same team and access group: the renewed profile keeps the keychain access group, so the new build
reads the same key and nothing needs migrating.

Development profiles are issued for a year. `build.sh` warns 60 days before one expires; renew it
the same way (step 1 for an App Development profile, step 2).
