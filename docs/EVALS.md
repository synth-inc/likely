# Evals

Likely's job is to put the file you want at the top of `~/Likely` before you go looking for it. Evals
measure that: a set of **cases** (what you typed, where, and which file you actually wanted) is run
through the app's real prompt and agent runner, and every answer is scored.

- **Cases** are JSON Lines. Your own live outside the repo; the repo ships a public, synthetic suite.
- **The runner** is the Likely binary itself in a headless mode (`--eval`), so it measures exactly what
  the app does: same prompt template, same agent runners and sandboxes, same FILE: filtering.
- **Capture** turns real use into cases: "Save as test" in the bar above a picker, or (opt-in)
  automatically saving every confirmed pick as a test.

## Running

Build a dev build (`./build.sh`) or a bare binary (`swift build -c release -Xswiftc -DLIKELY_DEV`), then:

```sh
APP=build/Likely.app/Contents/MacOS/Likely

$APP --eval fixtures --agent opencode            # public suite, OpenCode's free model
$APP --eval fixtures --agent claude --model haiku --tags image
$APP --eval personal --agent claude --model sonnet --k 3
$APP --eval ~/my-cases.jsonl --case lease,k1s --repeat 3
$APP --eval fixtures --dry-run                   # print the prompts; run nothing
```

| Option | Default | |
|---|---|---|
| `--eval <suite>` | | `fixtures` (repo suite), `personal` (your cases.jsonl), `all` (both), or a path to any `.jsonl` |
| `--agent <id>` | Settings | `claude`, `codex`, `gemini`, `opencode`, `hermes` |
| `--model <name>` | Settings | e.g. `haiku`, `sonnet`, `opencode/deepseek-v4.1-flash-free` |
| `--agent-path <path>` | auto-detected | agent executable |
| `--k <n>` | 8 | cutoff for pass/fail and hit@k (Likely shows at most 8) |
| `--timeout <sec>` | 120 | per case, all turns included |
| `--repeat <n>` | 1 | run each case n times (agents are not deterministic) |
| `--jobs <n>` | 1 | cases in parallel; keep 1 when comparing latency |
| `--tags a,b` / `--case id,id` | all | filter |
| `--prompt-file <file>` | Settings | try a different prompt template |
| `--out <dir>` | see below | results folder |
| `--no-isolate` | | don't sandbox cases that set `searchFolders` |
| `--verbose` | | also print Likely's log lines |

From the app: **Settings → Evals → Run Suite…** runs the same command as a subprocess and shows its
progress; **Open Last Report** opens the newest report.

Each run writes `~/Library/Application Support/Likely/evals/runs/<time>-<agent>-<model>/`:

- `results.json`: every case's suggestions, score, timings, cost, tool calls (schema: `EvalRun` in
  `Sources/LikelyEvalKit/EvalResults.swift`).
- `report.html`: self-contained report: summary tiles, per-tag table, per-case details, and a comparison
  with the previous run of the same suite, including which cases started or stopped passing. It prefers a
  previous run with the same agent, model, k, tags and `--case` filter; if there's none, it compares with
  the newest run of the suite and says which settings differ.
- `cases/<n>-<id>/prompt.txt` and `cases/<n>-<id>/transcript.jsonl`: the exact first message and the
  agent's raw stream (every turn, relaunches included). `<n>` is the case's position in the suite, so
  cases that share an id keep separate folders.
- `prompt-template.txt`: the template used (its hash is in the report, to tell prompt versions apart).

The command prints one line per case and a summary, and exits 0 when the run completes (whatever the
pass rate), 1 if the results couldn't be written, or 2 on a usage/setup error. A case passes only if it
ran to the end: a timeout or error counts as a failure even if the right file was already suggested.

Ctrl-C (SIGINT) or SIGTERM (what **Stop** in Run Suite sends) cancels the running cases, stops their
agents, skips the rest and writes partial results (marked *interrupted*); the exit status is then 130 or
143. Closing the Run Suite sheet or quitting Likely stops a run the same way.

### Dev builds only

Eval mode is a developer tool and doesn't check the license, so it exists only in dev builds
(`./build.sh`, which compiles with `LIKELY_DEV`). Release builds (`LIKELY_DISTRIBUTION=1`) contain no
`--eval` mode, no Settings → Evals tab and no "Save as test" in the bar; there's no flag to turn them on.
The case format and file handling (`LikelyEvalKit`) are in every build: search history uses them.
Dev builds also bundle `evals/fixtures` in the app, so the public suite runs from Settings too.

## Case format

One JSON object per line. Blank lines and lines starting with `#` or `//` are ignored.

```json
{"id":"k1s-2025","query":"my K1s from 2025","context":{"app":"TurboTax","windowTitle":"Upload documents"},"expect":{"folder":"~/Documents/Personal/Taxes/2025/K1s","mode":"folder-or-contents"},"tags":["documents","folder"],"source":"manual","notes":"","createdAt":"2026-11-04T18:00:00Z"}
```

| Field | | |
|---|---|---|
| `id` | required | unique within the file; used in reports and for comparing runs |
| `query` | required | a string, or an array of successive messages: the first starts the search, each later one is sent like typing again in the bar ("not these, …"; the previous suggestions count as rejected) |
| `context.app` | optional | app that opened the picker (default: "an app") |
| `context.windowTitle` | optional | title of the window behind the picker |
| `context.screenshot` | optional | path to a screenshot of that window. With one, the case runs like automatic mode (screenshot + "the user already added: …"); without, input-first (typed description only) |
| `context.button` | optional | the picker's confirm button ("Open", "Upload", …) |
| `context.userName` | optional | the name sent as `{{userName}}` ("The user is …"). Unset: none for personal cases (evals never send your real name), "Jordan Rivera" for `source: "fixture"` cases |
| `expect` | required | one of the three forms below; `{}` means "not filled in yet" (skipped) |
| `tags` | optional | free-form; filter with `--tags`, broken down in the report |
| `source` | optional | `manual`, `captured`, `history` or `fixture` |
| `notes`, `createdAt` | optional | for humans; ISO 8601 date |
| `searchFolders` | optional | tell the agent to search only these folders (see Isolation) |

Expectations:

- `{"anyOf": [paths]}`: passes if any of these is suggested within the top k. Use for "the right file,
  or this equally good copy".
- `{"allOf": [paths]}`: passes only if all are suggested within the top k. Recall = fraction found.
  In `anyOf` and `allOf`, an entry that is a folder counts as found when the folder or anything inside it is suggested, so "the K1s folder plus the K-1 filed under 1099s" is one `allOf` case.
- `{"folder": path, "mode": "folder-or-contents"}`: passes if the folder itself or anything inside it is
  suggested. Recall is 1 for the folder itself, else the fraction of its files suggested. With
  `"mode": "folder"`, only the folder itself counts.

Paths may start with `~`. Relative paths resolve against the folder containing the cases file (that's how
the fixture suite points at `evals/fixtures/files`). Symlinks are resolved and matching ignores case, as
it does for agent output.

## Scoring

Suggestions are the agent's `FILE:` lines that Likely would actually have shown: symlinks resolved,
duplicates dropped, and lines that Likely refuses (missing files, sensitive paths, Likely's own files) set
aside and listed in the report. For multi-turn cases the final turn's suggestions are scored (that's
what the user is looking at); earlier turns are kept in the report.

Per case: **pass/fail** (above), **rank** of the first expected hit, **hit@1 / hit@3 / hit@k**,
**recall**, **precision** (fraction of the top-k suggestions that were expected), **extras** (unexpected
suggestions), **latency** (seconds to the first usable FILE line, and total), **cost** (Claude Code
reports it; other agents don't), **tool calls** (counted from the transcript), and the transcript path.
The summary averages over cases with expectations.

The scoring code lives in `Sources/LikelyEvalKit` (no app dependencies) and is unit-tested:
`swift test`.

## Writing your own cases

Your cases live in `~/Library/Application Support/Likely/evals/cases.jsonl`. Ways to add one:

1. **"Save as test" in the bar above the picker** (next to "N found · Not these", once a search has
   finished). Pick your file and close the picker as usual; then a small editor opens, prefilled with what
   you typed, the app and window title, Likely's suggestions as checkboxes, and what you picked already
   checked. "Choose Other Files or Folders…" adds more; choose any of / all of / folder; Save.
   The editor deliberately waits until the picker has closed: a Likely window (or a second file panel)
   opening while the picker is up would take focus from it and could change its selection, and waiting
   means the actual pick can be prefilled as the answer.
2. **Settings → History → Make Eval** for any past search, including the most recent one (see Search history).
3. **Debug View → Make This a Test…** for any recent run, or **Settings → Evals → New Test…** from scratch.
4. **Automatic saving** (see Capture), or edit the file by hand.

Good cases are specific about *your* files: "the signed offer letter", "the PDF my landlord asked for",
"our logo with the transparent background". Use `anyOf` when there are equivalent copies, `allOf` when
the task genuinely needs several files, and `folder` when you'd upload or browse a whole folder. Tag cases
by kind (`image`, `documents`, `folder`, `context`, `multi-turn`, …) so the report shows where a prompt or
model is weak.

## Capture from real use

With **Settings → Evals → "Automatically save picks as tests"** turned on (off by default in every build),
each confirmed pick becomes a case in `cases.jsonl` right away, with no approval step: what you typed,
the app, the window title, the screenshot (if one was taken, saved encrypted as `…/evals/screenshots/<id>.png.enc`;
the case editor decrypts it in memory for its preview, and an eval run decrypts it into a temporary 0600
file in the case's own folder for the agent, deleted when the case ends), and the
file(s) you picked. Captured cases have `"source": "captured"` and the tag `captured`, so they're easy to
filter, edit or delete in Settings → Evals. Nothing is recorded for cancelled pickers, or when you neither
typed anything nor had a screenshot. If the pick can't be read, it stays out of your tests: it's logged
and kept in `drafts.jsonl`, shown under **Needs expected** in Settings → Evals, where you can choose the
file (Fix…) and add it to your tests, or discard it.

How the pick is read (Accessibility; `PickTracker` in `Sources/Likely/Evals/EvalCapture.swift`):

- **Selection.** NSOpenPanel's list view is an `AXOutline` (identifier `ListView`). Its
  `AXSelectedRows` are rows whose name cell contains an `AXTextField` with **`AXURL`** (a file reference
  URL such as `file:///.file/id=…`, turned into a path with `filePathURL`) and `AXFilename`. Column and
  icon views are read the same generic way: `AXSelectedRows` / `AXSelectedChildren` on any browser
  container, then `AXURL` a few levels below each selected item; folders above the pick (column view, the
  sidebar) are dropped. The window's `AXDocument` is empty for open panels. The selection is read on
  every poll and on every click or key press, because nothing can be read once the panel is gone.
- **Confirm vs. cancel.** A global event monitor notes mouse-downs on the panel's `AXDefaultButton` or
  `AXCancelButton`, Return/Enter, Escape/⌘., and double-clicks. The panel closing within a few seconds of a
  confirm is a pick; a cancel, or a close with no signal, records nothing.
- **Copies.** If you picked one of Likely's copies in `~/Likely`, the draft gets the original's path.
- If the pick can't be read (e.g. a sandboxed app's panel that Likely only sees as a window), the entry
  goes to drafts with `"expect": {}` and the tag `needs-expected`.

**Privacy.** Automatic saving is off by default in all builds. Everything stays on your Mac in
`~/Library/Application Support/Likely/evals`; nothing is uploaded, and no case runs until you start a run.

## Search history

With **Settings → History → "Save search history"** on (the default; independent of automatic saving),
every picker Likely searched for is kept in `~/Library/Application Support/Likely/History/history.jsonl`,
newest 500 only: the time, the app, the window title and confirm button, what you typed (in order), the
originals the agent suggested (not the `~/Likely` copies), and what you picked, when the picker was
confirmed and the pick could be read (same `PickTracker` as Capture). Pickers where nothing ran (nothing
typed in input-first mode, or no license), and a picker still open when Likely quits, aren't recorded.

**Privacy.** History never leaves the Mac and isn't included in eval runs.
- The folder is `0700` and the file `0600`. (Pre-release builds kept `history.jsonl` one level up; it's
  moved into `History/` on launch.)
- No search agent can read it: every `sandbox-exec` profile (`AgentSandbox.protectionRules`) denies all of
  `~/Library/Application Support/Likely` and `~/Library/Logs/Likely` except the run's work folder, and Codex
  gets a permission profile that extends its built-in read-only one with the same paths set to `"none"`
  (`AgentSandbox.codexFilesystem`). See [PRIVACY.md](PRIVACY.md).
- Each line is encrypted (AES-GCM, with a key in the Keychain): `lk1:<key id>:<base64>`. History saved
  by an older version is encrypted in place on first launch. A build that can't read the key (a dev build
  reading a release build's history, or the other way round) says "History can't be read by this build"
  and leaves those lines alone.
- The first time a search is recorded, Settings → History shows a short line about it (until you click
  OK), and the next picker's bar shows the same line once: "Likely keeps a private history of your
  searches on this Mac so you can turn them into tests. Turn it off in Settings → History."
- Turning the toggle off stops recording and asks whether to delete what's already saved. **Clear
  History…** deletes the file. Both mention `~/Library/Logs/Likely/likely.log`, which may still contain
  past queries and file paths (it's the debugging log; see below).
- Reading the pick (`PickTracker`, Accessibility) only runs while search history or automatic saving is
  on; with both off it never starts.

**Robustness.** Writes go through one serial background queue (never the main thread when a picker
closes), and rewrite the file atomically. If the file exists but can't be read (permissions, invalid
UTF-8), nothing is written, so a bad read never replaces your history with one entry. Lines are split on
`\n` only (a trailing `\r` is dropped): JSONEncoder doesn't escape U+2028, U+2029 or U+0085, so splitting
on every Unicode newline would cut entries in half. The list is only read while Settings → History is on
screen.

**The log.** `likely.log` keeps logging what it always has (window titles of pickers, follow-up text you
typed, file paths Likely copied) because it's what makes bug reports debuggable, and redacting only some
lines would suggest a privacy guarantee it doesn't give. History's own log lines don't include queries,
apps or paths.

Each row has **Make Eval**: a sheet with the query (editable, one message per line), the pick (checked)
and Likely's suggestions as checkboxes, **Add Files…** for anything else, and any-of / all-of. Saving
appends a case to `cases.jsonl` with `"source": "history"` and the tag `history`, and marks the row
"test saved" (if the search is no longer in the file by then, e.g. it aged out, the tab says the test
was saved but the row couldn't be marked). The entry format is `SearchHistoryEntry` in `Sources/LikelyEvalKit/SearchHistory.swift`;
unreadable lines are skipped, and kept until they age out.

## Privacy and the fixture suite

Your cases name your files, and running them sends those paths (and whatever the agent reads) to the
agent's model provider, just as using Likely does. That's why personal cases live outside the repo, and
why nothing runs them except you.

The public suite in `evals/fixtures` uses only synthetic files (`evals/fixtures/files`, regenerated by
`evals/fixtures/generate.py`): a lease, pay stubs, K-1s, invoices, a résumé, notes, a portrait-like
image, a landscape and an app icon, all for a made-up "Jordan Rivera". Its cases set
`searchFolders: ["files"]`, which turns on **isolation** (unless `--no-isolate`):

- the prompt's search folders become the fixture folder, plus a note to search only there;
- the prompt drops the template's "Elsewhere in ~ is fine too";
- the agent's sandbox denies reading **all of your home folder** and `/Volumes` (and your extra search
  folders), then allows back only the fixture folder, the case's work folder, the agent CLIs' own config
  and state (`~/.claude`, `~/.claude.json`, `~/.gemini`, `~/.hermes`, `~/.config`, `~/.local`, `~/.cache`,
  toolchains such as `~/.nvm` or `~/.bun`, shell startup files, the login keychain) and the agent's install
  folder. So a fixture run can't read `~/Likely`, `~/Library/Application Support/Likely` (your cases and
  their screenshots), `~/Library/Logs/Likely` or your documents. Rules are per case (`EvalIsolation` in
  `LikelyEvalKit`), so `--jobs` > 1 never mixes them up;
- Spotlight is blocked (its index would list your files by name), so agents use `ls`/`find`/`grep`;
- Hermes: its gateway runs inside the sandbox of the client that started it, so an eval never reuses a
  gateway it didn't start with the same rules (it restarts it) and stops its gateway when it exits.
  Isolated Hermes runs need `--jobs 1`.

**Codex can't be isolated**: it runs inside its own sandbox, which can't be nested. Isolated suites run
with Codex print a warning, keep only the prompt's "search there only", and are recorded as *not
isolated*; Run Suite shows a note when you pick Codex for the public fixtures.

## Code map

- `Sources/LikelyEvalKit/`: case format, path rules, scoring, results, reports (tested in `Tests/LikelyEvalKitTests`).
- `Sources/Likely/Evals/EvalCLI.swift`: `--eval` mode (suites, runner loop, dry-run sink, isolation).
- `Sources/Likely/Evals/EvalCapture.swift`: cases from real use (`EvalCapture`, `PickTracker`).
- `Sources/LikelyEvalKit/SearchHistory.swift`, `Sources/Likely/Evals/SearchHistorySettings.swift`: search
  history (file format, history → case) and Settings → History with the Make Eval sheet.
- `Sources/Likely/Evals/EvalsSettings.swift`: Settings → Evals and the case editor (also used by the bar's
  "Save as test" and the Debug View).
- Shared with the app: `PromptBuilder` (Coordinator.swift) builds every agent message;
  `LikelyFolder.screen(path:)` decides which FILE: lines Likely shows.
