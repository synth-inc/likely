# Likely

Menu bar app that notices when a macOS file picker opens and fills `~/Likely` with the files you probably need.
When the picker opens, the folder instantly gets your most recently added files (see below). When you
describe what you want in the bar above the picker, Likely asks your coding agent (Claude Code by default; with
the optional Screenshots permission and Settings → Send a screenshot with searches, it also sees the window
behind the picker) and clones its candidates into
`~/Likely` in place of the recent files. A file named `…<what the agent is doing>…` sits at the top of the folder as a live progress report.
The copies stay until the next picker opens (or 10 minutes after you close one), so apps that read the file later still find it.

**Recent files.** Often the file you want is the one you just downloaded, saved or screenshotted, so the
moment a picker opens Likely clones the 3 files with the newest Date Added in your search folders into the
folder, under a ` …Recent…` header (the leading space puts it on top by name; it's also newest by Date
Added). Folders, packages, hidden/sensitive paths, partial downloads, not-downloaded cloud files, files over
500 MB or on another volume, and dev/build folders (`node_modules`, `.build`, `DerivedData`, …) are skipped.
Files that came in one go (a copied folder, an unzipped archive) count once. Files apps write in the
background are left out: a file is kept if it was opened, is a screenshot or was downloaded, or else if it
arrived on its own, outside app and project folders (an Obsidian vault, a repo), and isn't still being
rewritten (`RecentSelector`, tested with `swift test`). The count (1–10) and an off switch are in Settings,
and `scripts/recent-files.sh [count] [-v]` prints what it would pick (`-v`: and why it skipped the rest). Menu → Jump to Likely Folder When a
Picker Opens (on by default) selects the folder in the picker's sidebar; when off, only once you search.

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
  snapshots the front window on every click / ⌘-shortcut (in memory) and keeps the one from just before the picker.
  It's written to disk (`run/context-<run>.png`, removed when the picker closes) and sent only when you search.
  Settings → Send a screenshot with searches turns all of it off.
- **Recent files** (`RecentFiles`, `LikelyFolder.showRecent`): a synchronous `MDQuery` sorted by
  `kMDItemDateAdded` (last hour, then day, then 30 days), falling back to the top level of Desktop /
  Downloads / Documents; runs on its own queue, then clones on the Likely folder's copy queue. Copies are
  tagged with an xattr so ones made just before a crash are removed at the next launch.
- **Claude** (`ClaudeRunner`): `claude -p --output-format stream-json` with read-only tools
  (Read/Glob/Grep, `mdfind`, `ls`, …). Claude prints `STATUS:` / `FILE:` lines; the app does the copying
  (APFS clones), so Claude never writes anything.
- **Tools** (`ToolStore`, `Sources/LikelyTools`): extra command-line tools you give the agent (e.g. image
  search with rclip), kept in `~/Library/Application Support/Likely/tools.json` and edited in Settings →
  Tools or by a coding agent. Their commands are added to each agent's allowlist and their instructions to
  the prompt. See [docs/TOOLS.md](docs/TOOLS.md).

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

The paid license and services are covered by the [Terms of Service](https://synth-inc.github.io/likely/terms.html)
([source](docs/terms.html)); what Likely sends and where is in the
[Privacy Policy](https://synth-inc.github.io/likely/privacy.html) ([source](docs/privacy.html)).
