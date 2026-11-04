# Evals

Likely's job is to put the file you want at the top of `~/Likely` before you go looking for it. Evals
measure that: a set of **cases** (what you typed, where, and which file you actually wanted) is run
through the app's real prompt and agent runner, and every answer is scored.

- **Cases** are JSON Lines. Your own live outside the repo; the repo ships a public, synthetic suite.
- **The runner** is the Likely binary itself in a headless mode (`--eval`), so it measures exactly what
  the app does: same prompt template, same agent runners and sandboxes, same FILE: filtering.
- **Capture** turns real use into draft cases: when you confirm a pick, Likely records what you typed
  and what you picked, for you to approve in Settings → Evals.

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
| `--allow-eval` | | required in release builds (or `LIKELY_ALLOW_EVAL=1`) |

From the app: **Settings → Evals → Run Suite…** runs the same command as a subprocess and shows its
progress; **Open Last Report** opens the newest report.

Each run writes `~/Library/Application Support/Likely/evals/runs/<time>-<agent>-<model>/`:

- `results.json`: every case's suggestions, score, timings, cost, tool calls (schema: `EvalRun` in
  `Sources/LikelyEvalKit/EvalResults.swift`).
- `report.html`: self-contained report: summary tiles, per-tag table, per-case details, and a comparison
  with the previous run of the same suite (any agent), including which cases started or stopped passing.
- `cases/<id>/prompt.txt` and `cases/<id>/transcript.jsonl`: the exact first message and the agent's raw stream.
- `prompt-template.txt`: the template used (its hash is in the report, to tell prompt versions apart).

The command prints one line per case and a summary, and exits 0 when the run completes (whatever the
pass rate) or 2 on a usage/setup error.

### Licensing

Eval mode doesn't check the license: it's a developer tool. Dev builds (`./build.sh`, `LIKELY_DEV`) allow it;
release builds refuse it unless you pass `--allow-eval` or set `LIKELY_ALLOW_EVAL=1`. Without `--eval`,
release builds behave exactly as before.

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
| `expect` | required | one of the three forms below; `{}` means "not filled in yet" (skipped) |
| `tags` | optional | free-form; filter with `--tags`, broken down in the report |
| `source` | optional | `manual`, `captured` or `fixture` |
| `notes`, `createdAt` | optional | for humans; ISO 8601 date |
| `searchFolders` | optional | tell the agent to search only these folders (see Isolation) |

Expectations:

- `{"anyOf": [paths]}`: passes if any of these is suggested within the top k. Use for "the right file,
  or this equally good copy".
- `{"allOf": [paths]}`: passes only if all are suggested within the top k. Recall = fraction found.
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

Your cases live in `~/Library/Application Support/Likely/evals/cases.jsonl`. Three ways to add one:

1. **Settings → Evals → New Test…**: type the query (one message per line), choose the expected files or
   folders with a file chooser, pick any of / all of / folder.
2. **Debug View → Make This a Test**: takes a real run's typed query, app and window title, and lets you
   choose the expected files (Likely's suggestions are one click away).
3. **Approve a draft** (see Capture) or edit the file by hand.

Good cases are specific about *your* files: "the signed offer letter", "the PDF my landlord asked for",
"our logo with the transparent background". Use `anyOf` when there are equivalent copies, `allOf` when
the task genuinely needs several files, and `folder` when you'd upload or browse a whole folder. Tag cases
by kind (`image`, `documents`, `folder`, `context`, `multi-turn`, …) so the report shows where a prompt or
model is weak.

## Capture from real use

When a picker closes with a confirmed pick, Likely saves a **draft** to `…/evals/drafts.jsonl` with
what you typed, the app, the window title, the screenshot (if one was taken, copied to
`…/evals/screenshots/`), and the file(s) you picked. Drafts show up in Settings → Evals → Drafts, where
you approve them (they move to cases.jsonl), fix the expected files, or discard them. Nothing is
recorded for cancelled pickers, or when you neither typed anything nor had a screenshot.

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
- If the pick can't be read (e.g. a sandboxed app's panel that Likely only sees as a window), the draft
  is still saved with `"expect": {}` and the tag `needs-expected`, for you to fill in.

**Privacy.** Capture is on by default only in dev builds. In release builds it's an opt-in toggle in
Settings → Evals ("Save my picks as draft tests"), off by default. Everything stays on your Mac in
`~/Library/Application Support/Likely/evals`; nothing is uploaded, and drafts are never run until you
approve them and start a run yourself.

## Privacy and the fixture suite

Your cases name your files, and running them sends those paths (and whatever the agent reads) to the
agent's model provider, just as using Likely does. That's why personal cases live outside the repo, and
why nothing runs them except you.

The public suite in `evals/fixtures` uses only synthetic files (`evals/fixtures/files`, regenerated by
`evals/fixtures/generate.py`): a lease, pay stubs, K-1s, invoices, a résumé, notes, a portrait-like
image, a landscape and an app icon, all for a made-up "Jordan Rivera". Its cases set
`searchFolders: ["files"]`, which turns on **isolation** (unless `--no-isolate`):

- the prompt's search folders become the fixture folder, plus a note to search only there;
- the agent's sandbox denies reading `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Pictures`, `~/Movies`,
  `~/Music`, iCloud Drive, `~/Library/CloudStorage`, Mail, Messages, app containers and your extra search
  folders (the fixture folder stays readable even if the repo lives under one of them);
- Spotlight is blocked (its index would list your files by name), so agents use `ls`/`find`/`grep`.

Codex runs inside its own sandbox, which can't be nested, so for Codex isolation is the prompt only.

## Code map

- `Sources/LikelyEvalKit/`: case format, path rules, scoring, results, reports (tested in `Tests/LikelyEvalKitTests`).
- `Sources/Likely/Evals/EvalCLI.swift`: `--eval` mode (suites, runner loop, dry-run sink, isolation).
- `Sources/Likely/Evals/EvalCapture.swift`: drafts from real use (`EvalCapture`, `PickTracker`).
- `Sources/Likely/Evals/EvalsSettings.swift`: Settings → Evals and the case editor (also used by the Debug View).
- Shared with the app: `PromptBuilder` (Coordinator.swift) builds every agent message;
  `LikelyFolder.screen(path:)` decides which FILE: lines Likely shows.
