# Evals

Likely's job is to put the file you want at the top of `~/Likely` before you go looking for it. Evals
measure that: a set of **cases** (what you typed, where, and which file you actually wanted) is run
through the app's real prompt and agent runner, and every answer is scored.

- **Cases** are JSON Lines. Your own live outside the repo; the repo ships a public, synthetic suite.
- **The runner** is the Likely binary itself in a headless mode (`--eval`), so it measures exactly what
  the app does: same prompt template, same agent runners and sandboxes, same FILE: filtering.
- **Capture** turns real use into cases: "Save as test" in the bar above a picker, or (opt-in)
  automatically saving every confirmed pick as a test.

In the app, cases are called **tests** (Settings → Tests), and every build can run your own: see
[Running your tests](#running-your-tests-every-build).

## Running your tests (every build)

Every build, including the one you download, can re-run **your own tests** and compare the result with
the previous run, from Settings or from the command line. The loop it's for:

1. **Save misses as tests**: "Save as test" in the bar above a picker, **Make Eval** in Settings → History,
   or automatic saving (Settings → Tests, off by default). See [Writing your own cases](#writing-your-own-cases).
2. **Change something**: add a tool (Settings → Tools, or your coding agent; see [TOOLS.md](TOOLS.md)), edit
   the prompt (Settings → Prompt), or switch agent or model.
3. **Re-run** and **compare**: the summary says how many tests pass, which started or stopped passing, and
   whether your tools changed since the previous run ("tools changed: +rclip").

### From Settings

**Settings → Tests** lists your tests (search, filter by tag, Edit, delete, New Test…) and the drafts that
need an expected file. **Run Tests…** picks the agent (the current one by default; only agents Likely found),
the model, and **with or without your tools** (with, by default), then shows progress, the pass count, the
comparison with the previous run, and **Open Report**. **Open Report** in the tab opens the last run's
report.

The row at the bottom is for the command line: the exact command with **Copy Command**, **Copy for Coding
Agent** (instructions for Claude Code, Codex, …: run the tests before and after a change and report the
difference), and **Install Command…**, which writes a small `likely` script to `~/.local/bin` (never with an
administrator password, never over a file Likely didn't write, and not while Likely runs from the
temporary copy macOS makes of a fresh download) so `likely --json` runs your tests.

**Allow command-line test runs** (off by default) has to be on for the command below to run in a release
build: until then it exits with status 4 and says so. Run Tests in Settings works either way (it hands the run
it starts a one-time token, valid for 60 seconds; see [PRIVACY.md](PRIVACY.md#protected-settings)). In builds with a provisioning profile the switch is a protected
setting (see [PRIVACY.md](PRIVACY.md#protected-settings)): turning it on with `defaults write` doesn't count.

### From the command line, or your coding agent

```sh
/Applications/Likely.app/Contents/MacOS/Likely --eval personal            # summary on stdout
/Applications/Likely.app/Contents/MacOS/Likely --eval personal --json     # JSON on stdout
/Applications/Likely.app/Contents/MacOS/Likely --eval personal --agent codex --model gpt-5.6-luna --tag image
/Applications/Likely.app/Contents/MacOS/Likely --eval personal --without-tools   # what do my tools add?
```

It opens no window, no menu bar item and no onboarding, and works while the menu bar app is running.

| Option | Default | |
|---|---|---|
| `--eval personal` | | your tests: `~/Library/Application Support/Likely/evals/cases.jsonl` |
| `--agent <id>` | Settings | `claude`, `codex`, `gemini`, `opencode`, `hermes`: only one installed in a fixed place (below), run from there |
| `--model <name>` | Settings | e.g. `haiku`, `sonnet`, `opencode/deepseek-v4.1-flash-free` |
| `--case <id>` | all | only these tests (repeat the option, or separate ids with commas) |
| `--tag <tag>` | all | only tests with one of these tags (repeatable; `--tags a,b` works too) |
| `--k <n>` | 8 | pass if an expected file is in the top n (1-8) |
| `--timeout <sec>` | 120 | per test, all turns included (10-600) |
| `--jobs <n>` | 1 | tests in parallel (1-4; Hermes: 1); keep 1 when comparing times |
| `--repeat <n>` | 1 | run each test n times (1-5; agents aren't deterministic) |
| `--with-tools` / `--without-tools` | with | your approved tools, or the built-in search commands only, for every test |
| `--json` | | machine-readable results on stdout |
| `--verbose` | | also print Likely's (redacted) log lines on stderr |

The prompt is always the one in Settings → Prompt, and your name is never sent (see Case format).

**Output.** Progress (one line per test: `[2/5] PASS lease  rank 1  12.3s  $0.0042`) and warnings go to
stderr. The summary goes to stdout, ending with the paths of `results.json` and `report.html`; with
`--json`, stdout holds only one JSON object (the summary goes to stderr):

| Field | |
|---|---|
| `status`, `exitCode`, `error` | `completed`, `interrupted` or `error` (then `error` says why, and the other fields are absent). Fields without a value are left out |
| `suite`, `agent`, `model`, `k`, `promptHash` | what ran |
| `runFolder`, `resultsPath`, `reportPath` | the run's files |
| `summary` | `cases`, `scored`, `passed`, `failed`, `passRate`, `hitAt1`, `hitAt3`, `hitAtK`, `meanRecall`, `medianFirstFileSeconds`, `medianTotalSeconds`, `totalCostUSD` (Claude Code only), `timeouts`, `errors` |
| `cases[]` | `id`, `attempt`, `pass`, `status`, `rank` (of the first expected file; absent if none was suggested), `totalSeconds`, `firstFileSeconds`, `costUSD`, `usedTools`, `error` |
| `tools` | `active` (`id` and `hash` of each tool the agent got), `hash` (of the set), `pendingApproval` (tools changed outside Likely, not used until you approve them in Settings → Tools), `casesWithoutTools` |
| `comparison` | absent on the first run; else `previousRunFolder`, `previousStartedAt`, `previousAgent`, `previousModel`, `previousPassed`, `previousScored`, `previousPassRate`, `passedDelta`, `passRateDelta`, `settingsDiffer` (non-empty: not like for like), `toolsChanged`, `toolChanges` (`+id` added, `-id` removed, `~id` edited), `nowPassing`, `nowFailing` |

**Exit status**

| | |
|---|---|
| 0 | the run completed, whatever the pass rate |
| 1 | an error: the agent isn't installed (or the one chosen in Settings can't run tests), no saved tests, another run in progress, `evals/` or `runs/` is a symbolic link, results couldn't be written |
| 2 | a usage error: an unknown option, an option release builds refuse (below), a bad value |
| 3 | Likely isn't licensed (paid builds; the same check as searches, from the license Likely last confirmed: open Likely to buy, restore or re-check one). Free builds (`LIKELY_FREE`) never check |
| 4 | command-line runs are off: turn on **Allow command-line test runs** in Settings → Tests |
| 130 / 143 | stopped by Ctrl-C (SIGINT) or SIGTERM: running tests are cancelled, partial results written |

**What release builds refuse.** Anything that would let the caller choose a program, file or folder that
Likely then uses: `--agent-path`, `--prompt-file`, `--out`, a cases file or `fixtures`/`all` as the suite,
`--no-isolate`/`--isolate`, `--dry-run`, any other or single-dash argument, and option values starting
with `-`. That parser is the guarantee against preference overrides: Foundation reads `-claudePath /x`
anywhere on the command line as a preference, so no such argument gets through. `--model` must look like a
model name.

- **Agents** are found only in fixed places: `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, and each nvm Node version's `bin` (newest first). No
  login shell runs (its startup files are anyone's to edit), and the Claude path saved in Settings is used
  only if it's one of those places.
- **Settings** that decide what runs (agent, models, Claude path, prompt, tool approvals, the switch above)
  are protected in builds with a provisioning profile: a value changed outside Likely is ignored and the
  default used (see [PRIVACY.md](PRIVACY.md#protected-settings)).
- **Screenshots** are never used by test runs: a case's `context.screenshot` is ignored (nothing is decrypted
  or copied).
- **Environment.** The run re-executes itself in a clean environment rebuilt from your user account (home,
  user, shell, the standard `PATH`, temporary folder, locale), plus the proxy and certificate settings
  launchd gives apps (`launchctl getenv` of `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, `ALL_PROXY` and their
  lowercase forms, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`). Nothing the
  caller sets, such as `DYLD_*`, `NODE_OPTIONS`, `PATH`, `ZDOTDIR` or `CFFIXED_USER_HOME`, reaches Likely or
  the agents, so agents start as they do from the app. `LIKELY_EVALS_DIR` and `LIKELY_FIXTURES` are dev-only.
- **Sessions.** Codex's and Hermes' saved conversations are deleted before the run exits, whichever way it
  ends (finished, an error, Ctrl-C), not in the background. Agents start with default signal handling.

Everything else is what the app does: the same prompt, sandbox profiles, tool approval (an unapproved tool
isn't used, and the run says so), private data rules, owner-only files and redacted log.

**Running next to the app.** A run and the app share files, so:
- One run at a time: a run holds `evals/.run.lock` (flock) while it runs; a second one (from Settings or a
  command) exits 1 at once. This also keeps the runs folder and `last-run.txt` consistent.
- `cases.jsonl`/`drafts.jsonl` and the search history are read and written under a lock file in their
  folder (`.likely.lock`), so an append in one process is never seen half written or lost by another.
  A run only reads your cases and never writes history.
- Hermes: runs use their own profile, `likely-eval` (a copy of the app's `likely` profile when it has
  one), so a run never stops the app's gateway or leaves one with a test's sandbox rules for the app. They
  also run one test at a time (`--jobs 1`): the gateway is shared by every case and runs in the sandbox of
  the case that started it, which may read that case's folder, so parallel cases could see each other's.
- Run folders get unique names (`-2`, … when two start in the same second), and are never written through
  a symlinked `evals/` or `runs/` (only the data folder itself may be a link, to `Likely.noindex`). Lock
  files are opened without following symlinks and must be regular files; on a file system without locks
  (`ENOTSUP`) the lock is skipped everywhere alike.
- Runs are pruned after each run: the newest 20 are kept, and none older than 30 days. A run that was
  stopped early is never used as "the previous run".

### Dev builds

Dev builds (`./build.sh`, or `swift build -c release -Xswiftc -DLIKELY_DEV`) accept everything above plus
the developer options, and don't check the license:

```sh
APP=build/Likely.app/Contents/MacOS/Likely

$APP --eval fixtures --agent opencode            # public suite, OpenCode's free model
$APP --eval fixtures --agent claude --model haiku --tags image
$APP --eval personal --agent claude --model sonnet --k 3
$APP --eval ~/my-cases.jsonl --case lease,k1s --repeat 3
$APP --eval fixtures --dry-run                   # print the prompts; run nothing
```

| Option | |
|---|---|
| `--eval <suite>` | also `fixtures` (repo suite), `all` (personal + fixtures), or a path to any `.jsonl` |
| `--agent-path <path>` | agent executable (default: auto-detected) |
| `--prompt-file <file>` | try a different prompt template |
| `--out <dir>` | results folder |
| `--no-isolate` | don't sandbox cases that set `searchFolders` |
| `--with-tools` | give fixture cases your tools too (see Your tools) |
| `--dry-run` | print the prompts; run nothing |

`LIKELY_EVALS_DIR` moves the evals folder and `LIKELY_FIXTURES` points at another fixtures folder. Dev
builds also bundle `evals/fixtures` in the app, so Run Tests offers the public suite too.
`scripts/test-eval-cli.sh` tests the release command line end to end with a fake agent and a fake home
folder (in a build made with `LIKELY_EVAL_TEST_SEAM`, which nothing else sets).

### Run files

Each run writes `~/Library/Application Support/Likely/evals/runs/<time>-<agent>-<model>/` (owner-only):

- `results.json`: every case's suggestions, score, timings, cost, tool calls, and the run's tools (schema:
  `EvalRun` in `Sources/LikelyEvalKit/EvalResults.swift`).
- `report.html`: self-contained report: summary tiles, per-tag table, per-case details, and a comparison
  with the previous run of the same suite, including which cases started or stopped passing. It prefers a
  previous run with the same agent, model, k, tags and `--case` filter; if there's none, it compares with
  the newest run of the suite and says which settings differ. When your tools differ from that run's,
  it says so too ("tools changed: +rclip"), without passing over the run: see Your tools.
- `cases/<n>-<id>/prompt.txt` and `cases/<n>-<id>/transcript.jsonl`: the exact first message and the
  agent's raw stream (every turn, relaunches included). `<n>` is the case's position in the suite, so
  cases that share an id keep separate folders. The agent runs in `cases/<n>-<id>/agent/`, the only part
  it may read: its config files, never the prompt or transcript files.
- `prompt-template.txt`: the template used (its hash is in the report, to tell prompt versions apart).

A case passes only if it ran to the end: a timeout or error counts as a failure even if the right file was
already suggested. Closing the Run Tests sheet or quitting Likely stops a run started there (SIGTERM).

The case format and file handling (`LikelyEvalKit`) are in every build: search history uses them.

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
| `context.screenshot` | ignored | written by older versions, which sent a screenshot with the search. Still accepted so old cases load; Likely no longer sends screenshots |
| `context.button` | optional | the picker's confirm button ("Open", "Upload", …) |
| `context.userName` | optional | the name sent as `{{userName}}` ("The user is …"). Unset: none for personal cases (evals never send your real name), "Jordan Rivera" for `source: "fixture"` cases |
| `context.useTools` | optional | `true`/`false`: whether the agent gets your tools (tools.json) for this case. Unset: personal cases do, fixture cases don't (see Your tools) |
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

## Your tools

Tools you add in Settings → Tools (tools.json, see [TOOLS.md](TOOLS.md)) change what the agent can do,
so evals handle them explicitly:

- **Personal cases** (your cases.jsonl, any file you pass, and cases whose `source` isn't `fixture`) run
  with your enabled, approved tools, exactly as the app does: their prompt section, their command
  allowlist entries and the sandbox profile that comes with them. Add a tool and run the evals again,
  and the comparison measures the tool.
- **Fixture cases** (`source: "fixture"`, or anything in `evals/fixtures/cases.jsonl`) ignore your tools
  by default, so public-suite results stay comparable across machines: no tools section in the prompt,
  no allowlist entries, and the default (non-tools) sandbox profile. `--with-tools` gives them your tools
  for one run; `"context": {"useTools": true}` does it for one case.
- A case's `context.useTools` wins either way (`false` keeps a personal case on the built-in commands only).
- The tools are read once, when the run starts, so every case of a run sees the same set.

Every run records the tools the agent got in `results.json` (`tools`: each tool's id with a hash of its
commands and instructions, plus a hash of the set; empty when no case used them) and each case's
`usedTools`. The report and the printed summary show them ("Tools: rclip (1a2b3c4d)"), and the
comparison with the previous run flags a different set: `+id` added, `-id` removed, `~id` edited
(commands or instructions). A tool change doesn't count as different settings when picking the previous
run, since comparing against the run before the tool is the point. Runs from before tools were recorded
show no tools line and no tool comparison.

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
3. **Debug View → Make This a Test…** for any recent run, or **Settings → Tests → New Test…** from scratch.
4. **Automatic saving** (see Capture), or edit the file by hand.

Good cases are specific about *your* files: "the signed offer letter", "the PDF my landlord asked for",
"our logo with the transparent background". Use `anyOf` when there are equivalent copies, `allOf` when
the task genuinely needs several files, and `folder` when you'd upload or browse a whole folder. Tag cases
by kind (`image`, `documents`, `folder`, `context`, `multi-turn`, …) so the report shows where a prompt or
model is weak.

## Capture from real use

With **Settings → Tests → "Automatically save picks as tests"** turned on (off by default in every build),
each confirmed pick becomes a case in `cases.jsonl` right away, with no approval step: what you typed,
the app, the window title, and the file(s) you picked. Captured cases have `"source": "captured"` and the tag `captured`, so they're easy to
filter, edit or delete in Settings → Tests. Nothing is recorded for cancelled pickers, or when you didn't
type anything. If the pick can't be read, it stays out of your tests: it's logged
and kept in `drafts.jsonl`, shown under **Needs expected** in Settings → Tests, where you can choose the
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
every picker Likely searched for is kept in `~/Library/Application Support/Likely/History/history.enc.jsonl`
(`history.jsonl` in builds without encryption),
newest 500 only: the time, the app, the window title and confirm button, what you typed (in order), the
originals the agent suggested (not the `~/Likely` copies), and what you picked, when the picker was
confirmed and the pick could be read (same `PickTracker` as Capture). Pickers where nothing ran (nothing
typed, or no license), and a picker still open when Likely quits, aren't recorded.

**Privacy.** History never leaves the Mac and isn't included in eval runs.
- The folder is `0700` and the file `0600`. (Pre-release builds kept `history.jsonl` one level up; it's
  moved into `History/` on launch.)
- No search agent can read it: every `sandbox-exec` profile (`AgentSandbox.protectionRules`) denies all of
  `~/Library/Application Support/Likely` and `~/Library/Logs/Likely` except the run's work folder, and Codex
  gets a permission profile that extends its built-in read-only one with the same paths set to `"none"`
  (`AgentSandbox.codexFilesystem`). See [PRIVACY.md](PRIVACY.md).
- In builds with encryption (official releases; see [BUILDING.md](BUILDING.md)) each line is encrypted
  (AES-GCM, with a key in the data-protection keychain): `lk1:<key id>:<base64>`. Plaintext history (an
  older version's, or a build without encryption's) is moved into the encrypted file on launch. A build
  without encryption leaves the encrypted file alone and says "History is encrypted by another build of
  Likely"; lines sealed with a key this build can't read are reported and left alone too.
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
why nothing runs them except you (or a coding agent you ask to: `Likely --eval personal`).

The public suite in `evals/fixtures` uses only synthetic files (`evals/fixtures/files`, regenerated by
`evals/fixtures/generate.py`): a lease, pay stubs, K-1s, invoices, a résumé, notes, a portrait-like
image, a landscape and an app icon, all for a made-up "Jordan Rivera". Its cases set
`searchFolders: ["files"]`, which turns on **isolation** (unless `--no-isolate`):

- the prompt's search folders become the fixture folder, plus a note to search only there;
- the prompt drops the template's "Elsewhere in ~ is fine too";
- the agent's sandbox denies reading **all of your home folder** and `/Volumes` (and your extra search
  folders), then allows back only the fixture folder, the case's `agent` folder, the agent CLIs' own config
  and state (`~/.claude`, `~/.claude.json`, `~/.gemini`, `~/.hermes`, `~/.config`, `~/.local`, `~/.cache`,
  toolchains such as `~/.nvm` or `~/.bun`, shell startup files, the login keychain) and the agent's install
  folder. So a fixture run can't read `~/Likely`, `~/Library/Application Support/Likely` (your cases), `~/Library/Logs/Likely` or your documents. Rules are per case (`EvalIsolation` in
  `LikelyEvalKit`), so `--jobs` > 1 never mixes them up;
- Spotlight is blocked (its index would list your files by name), so agents use `ls`/`find`/`grep`;
- Hermes: its gateway runs inside the sandbox of the client that started it, so an eval never reuses a
  gateway it didn't start with the same rules (it restarts it) and stops its gateway when it exits.
  Isolated Hermes runs need `--jobs 1`.

**Codex can't be isolated**: it runs inside its own sandbox, which can't be nested. Isolated suites run
with Codex print a warning, keep only the prompt's "search there only", and are recorded as *not
isolated*; Run Tests shows a note when you pick Codex for the public fixtures.

## Code map

- `Sources/LikelyEvalKit/`: case format, path rules, scoring, results, reports, which cases get your tools
  (`EvalToolPolicy`, `EvalToolSet` in EvalTools.swift) (tested in `Tests/LikelyEvalKitTests`).
- `Sources/LikelyEvalKit/EvalCommandLine.swift`: `--eval` options and what release builds accept
  (`EvalOptions`), the clean environment (`EvalEnvironment`), exit codes and the `--json` output
  (`EvalCLIResult`); tested in `EvalCommandLineTests`.
- `Sources/Likely/Evals/EvalCLI.swift`: `--eval` mode (suites, runner loop, dry-run sink, isolation, license
  check, run lock, clean-environment restart).
- `Sources/LikelyStorage/FileLock.swift`: the cross-process locks (cases, history, one run at a time).
- `Sources/Likely/Evals/EvalCapture.swift`: cases from real use (`EvalCapture`, `PickTracker`).
- `Sources/LikelyEvalKit/SearchHistory.swift`, `Sources/Likely/Evals/SearchHistorySettings.swift`: search
  history (file format, history → case) and Settings → History with the Make Eval sheet.
- `Sources/Likely/Evals/EvalsSettings.swift`: Settings → Tests, Run Tests (a `--eval … --json`
  subprocess), the command-line row and `likely` shim (`EvalCommand`), and the case editor (also used by
  the bar's "Save as test" and the Debug View).
- Shared with the app: `PromptBuilder` (Coordinator.swift) builds every agent message;
  `LikelyFolder.screen(path:)` decides which FILE: lines Likely shows.
