# Likely

Menu bar app that notices when a macOS file picker opens, asks Claude Code what file you probably
need (based on a screenshot of the window behind the picker), and clones the candidates into `~/Likely`.
A file named `…<what Claude is doing>…` sits at the top of the folder as a live progress report.
The copies stay until the next picker opens (or 10 minutes after you close one), so apps that read the file later still find it.

## Build & run

```sh
./build.sh            # → build/Likely.app (signed with your Apple Development identity)
open build/Likely.app
```

The setup window walks through Accessibility, Screen Recording, creating `~/Likely` (drag it into
the Finder sidebar), and finding the `claude` CLI.

For debugging, run the bare binary from a terminal (`.build/release/Likely`): it inherits the
terminal's Accessibility / Screen Recording grants and logs to stderr.

## Releases & updates

Likely updates itself with [Sparkle](https://sparkle-project.org). The feed is
`public/likely/appcast.xml` on onit-server (`SUFeedURL` in Info.plist); updates are signed with an
EdDSA key kept in the release machine's login Keychain (account `likely`).

```sh
scripts/bump-version.sh patch && git commit -am "Bump version"
scripts/release.sh --dry-run   # build, Developer ID sign, Likely.dmg, notarize, appcast → build/release
scripts/release.sh             # same, then tag vX.Y.Z, GitHub Release with Likely.dmg, write the appcast
```

Then commit and deploy the appcast in onit-server (the script prints the commands).

## How it works

- **Detection** (`AXWatcher`, `PickerHeuristics`): AX observers on every app. NSOpenPanel windows have
  `AXIdentifier` `open-panel` (Chrome: `AXSheetCreated`; TextEdit: `AXFocusedWindowChanged` /
  `AXWindowCreated`) and the sandboxed system dialog is `OpenPanel`. Button/browser heuristics are the fallback.
- **Close**: `AXUIElementDestroyed` on the panel, plus a poll for the panel's frame disappearing.
- **Screenshot** (`WindowCapture`): once open, the picker is drawn into the app's window, so the app
  snapshots the front window on every click / ⌘-shortcut (in memory) and uses the one from just before the picker.
- **Claude** (`ClaudeRunner`): `claude -p --output-format stream-json` with read-only tools
  (Read/Glob/Grep, `mdfind`, `ls`, …). Claude prints `STATUS:` / `FILE:` lines; the app does the copying
  (APFS clones), so Claude never writes anything.

## Evals

`Likely --eval fixtures --agent opencode` runs the public eval suite (synthetic files in `evals/fixtures`)
headlessly through the app's real prompt and agent runner, and writes `results.json` + `report.html`.
Eval mode, Settings → Evals and "Save as test" exist only in dev builds (`./build.sh`), not in release builds.
Your own cases live in `~/Library/Application Support/Likely/evals/cases.jsonl` ("Save as test" in the bar above a
picker, Settings → History → Make Eval, Settings → Evals, or automatic saving of picks). See [docs/EVALS.md](docs/EVALS.md).

Logs: `~/Library/Logs/Likely/likely.log` (menu → Verbose AX Logging logs every AX event).

## License

Likely is free software under the [GNU General Public License v3.0](LICENSE). The paid builds fund development;
if you'd rather build it yourself, `LIKELY_FREE=1 ./build.sh` skips the license step.
