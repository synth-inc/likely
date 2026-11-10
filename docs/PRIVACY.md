# Your data

Likely keeps everything on this Mac. Nothing listed here is uploaded by Likely itself. The search
agent you choose does send your query, the app name, the window title and what it reads while
searching to its model provider; that's how the search works.

Likely takes no screenshots and doesn't ask for Screen Recording. (Earlier versions could send a
screenshot of the window behind the picker; at launch Likely deletes any they left, see "Less on disk".)
If you allowed Screen Recording for an earlier version, you can remove Likely from System Settings →
Privacy & Security → Screen Recording.

## What Likely stores, and where

| What | Where | Protection |
| --- | --- | --- |
| Search history (what you typed, the app, suggestions, the pick; last 500) | `~/Library/Application Support/Likely/History/history.enc.jsonl` (encrypted), or `history.jsonl` in builds without encryption | Encrypted (official releases), owner-only, agents can't read it |
| Your test cases and drafts | `…/Likely/evals/cases.jsonl`, `drafts.jsonl` | Plaintext (see below), owner-only, agents can't read them |
| Test runs (results, reports, transcripts) | `…/Likely/evals/runs/` | Owner-only, agents can't read them (a running case reads only its own folder); the newest 20 kept, none older than 30 days |
| Your extra agent tools | `…/Likely/tools.json` | Plaintext (see below), owner-only, agents can't read it |
| Agent transcript of the last search | `…/Likely/transcripts/last-run.jsonl`, only while "Log details for troubleshooting" is on (dev builds: always) | Owner-only, agents can't read it; deleted when details turn off and at launch |
| The agent CLIs' own session files | Their own folders (see "The agents' own session files") | Turned off or deleted when the picker closes; other agents can't read them |
| Copies Likely made in the Likely folder (bookkeeping) | `…/Likely/likely-manifest.json` | Owner-only |
| Log (events, timings, counts; no queries, titles, paths or agent text, see "The log") | `~/Library/Logs/Likely/likely.log` | Owner-only, agents can't read it |
| Detailed log, only while "Log details for troubleshooting" is on (dev builds: always) | `~/Library/Logs/Likely/likely-details.log` | Owner-only, agents can't read it; deleted when details turn off and at launch |
| Settings, tool approvals | `~/Library/Preferences/inc.synth.likely.plist` | Agents can't write them |
| Encryption key | Data-protection keychain, access group `<team id>.inc.synth.likely`, "Likely data key" (`inc.synth.likely.data-key`) | Only Likely can read it; this device only, never synced |
| Settings seal marker | Same keychain and access group, "Likely settings seal" (account `settings-sealed`) | Records that older settings were sealed once (see Protected settings) |

`…/Likely` is `~/Library/Application Support/Likely`. Since this version it is a link to
`…/Likely.noindex`, and `~/Library/Logs/Likely` a link to `~/Library/Logs/Likely.noindex` (see Spotlight).

## How it's protected

**Owner-only permissions.** Folders are 0700 and files 0600 (other user accounts on the Mac can't open
them). Files are created that way, never written readable and narrowed afterwards. On launch Likely also
fixes anything older versions (or an editor saving tools.json) left wider.

**Agents can't read it.** Every agent runs in a sandbox that denies reading and writing
`~/Library/Application Support/Likely` and `~/Library/Logs/Likely`: `sandbox-exec` for Claude Code, Gemini
CLI, OpenCode and Hermes (`AgentSandbox.protectionRules`), Codex's own permission profile for Codex
(`AgentSandbox.codexFilesystem`). The only exception is the run's work folder: `…/Likely/run` for a search
(OpenCode's config, Gemini's settings, Hermes's helper), and the case's own folder's `agent` subfolder
for an eval. That folder holds only what the agent needs: the agents' config files. Transcripts, the prompt and results are kept next to it, never in it (Codex's
sandbox can only allow or deny whole paths, so a transcript inside would be readable to Codex); the
`sandbox-exec` profiles also deny `*.jsonl` in it. So a prompt-injected or curious agent can't read your
history, your tests and their expected answers, earlier eval reports, transcripts, or the log. tools.json
needs no exception: the agents get your tools in their prompt.

The folders above Likely's data can't be moved out from under those rules either: the `sandbox-exec`
profiles deny renaming or deleting `~`, `~/Library`, `~/Library/Application Support`, `~/Library/Logs`
and Likely's folders and links themselves (otherwise renaming `Application Support` would make the data
readable under the new name). Those rules name the folders' own entries only, so agents can still
create files inside them where their profile allows writes. Codex's read-only profile allows no writes
at all, so it can't rename anything.

**Encryption.** Encryption is on in official releases, and off in builds without a provisioning
profile (`./build.sh` by default). Settings → History shows which: "Encryption: on", or "Encryption: off
in this build (no provisioning profile)" with a link to [BUILDING.md](BUILDING.md), which explains how to
turn it on with your own Apple team.

With encryption on, search history is encrypted with AES-256-GCM. The
random key is kept in the data-protection keychain, in Likely's own access group
(`<team id>.inc.synth.likely`). Only apps signed by Likely's team with that group in their entitlements
can read it, and no other app can be given access to it. It's readable after first unlock, on this
device only, and not synced. Likely finds its team and access group in its own code signature at
launch; nothing is hard-coded. Reading the key never shows a prompt. If it can't be read, Likely
reports that instead, and doesn't make a new key over it. If two copies of Likely make the key at
the same moment, the second one uses the first one's.

If the Keychain doesn't answer in a build that encrypts (it's locked before the first login, or
something else is wrong), that's an error, not "encryption off": nothing meant to be encrypted is
written in plaintext. Settings → History shows "Encryption: on, but the Keychain isn't answering"
in orange. New searches wait in memory, and are saved, encrypted, once the Keychain answers (with the
next search, or Likely's own check every minute). They're lost if Likely quits first. Saved history
shows as "can't be opened right now", and is kept as it is.

History is encrypted line by line (`lk1:<key id>:<base64>` per line) rather than as one blob, so it
keeps the guarantees it has in plaintext:
- a line that can't be opened is skipped and kept in place rather than breaking the file;
- a file that can't be read is never overwritten;
- lines are split on `\n` only.

The cost is that the number of entries and their approximate sizes are visible.

Encrypted and plaintext history are kept in separate files (`history.enc.jsonl`, `history.jsonl`). A
build with encryption encrypts plaintext history on launch, then deletes the plaintext. A build without
encryption leaves encrypted history alone: Settings → History says "History is encrypted by another
build of Likely", and it keeps its own history unencrypted. Nothing is wiped.

Without encryption, the data has every other protection here: owner-only files, the agents can't read
it, and it's kept out of Spotlight. There's deliberately no weaker fallback, such as a key file next to
the data, or the login keychain with its "wants to use your confidential information" prompts.

**The agents' own session files.** The agent CLIs keep their own record of every conversation, with
your queries. Likely keeps them only as long as it needs them:
- Claude Code runs with `--no-session-persistence`, so it writes nothing to `~/.claude/projects`.
  Follow-ups go to the same running process.
- Codex, Gemini CLI, OpenCode and Hermes need theirs to continue the conversation when you type a
  follow-up, so it's deleted when the picker closes: Codex's rollout file in
  `~/.codex/sessions/<date>/`, Gemini's `~/.gemini/tmp/<hash of Likely's work folder>` (the chat and
  `logs.json`) and `~/.gemini/history/<same>`, the session in OpenCode's database
  (`opencode session delete`), and the session in Likely's own Hermes profile (`hermes sessions delete`).
- Meanwhile, no agent can read another agent's session files, or yours if you use those CLIs yourself:
  `~/.claude/projects`, `~/.claude/history.jsonl`, `~/.codex/sessions`, `~/.codex/archived_sessions`,
  Codex's history, logs and databases (`~/.codex/*.sqlite`), `~/.gemini/tmp`, `~/.gemini/history`,
  `~/.local/share/opencode` and `~/.hermes/profiles/likely` are denied to them. An agent can still read its
  own: those CLIs read them in the same process their tools run in, so they can't be told apart. Codex
  reads its own outside its sandbox, so its commands are denied all of them.

What's left: Codex also records each conversation in its own databases (`~/.codex/state_*.sqlite`,
`~/.codex/logs_*.sqlite`), which Likely doesn't edit; OpenCode may keep file snapshots and logs in
`~/.local/share/opencode`; a Hermes turn that's still finishing when the picker closes may write to the
session after it was deleted; and an agent that crashes, or a Likely that quits mid-search, leaves the
session in place. Agents can't read any of these. Earlier versions of Likely didn't delete these files;
delete Likely's folders in `~/.claude/projects` (their names contain `Application-Support-Likely`) to
remove what they left.

**Less on disk.** Earlier versions could take screenshots. At launch Likely deletes any they left
(`LegacyScreenshots`), and stops checking once a launch finds none: screenshots saved with tests
(`…/Likely/evals/screenshots/`, encrypted or not), the screenshot sent with a search (`…/Likely/run/context*.png`), the debug view's copies
(`…/Likely/debug/*.png`) and decrypted copies a killed eval run left (`screenshot-<id>.png` under
`…/Likely/evals/runs/<run>/cases/<case>/agent/`). It deletes only files with those names in those
folders, and follows no links out of Likely's folder. If `…/Likely` is a link somewhere other than
`Likely.noindex` next to it (you redirected the folder), Likely leaves it alone, logs that, and you can
delete those files yourself. Test cases that still name a screenshot load, but the field is ignored, and
a case saved with no query (one that searched on a screenshot alone) is skipped by eval runs and shows
"needs a query" in Settings → Tests.

**Test runs are pruned.** Each run's prompt, transcripts and results stay in `evals/runs/` only until the
run after it: then the newest 20 runs are kept, and any older than 30 days deleted (the run just made and
the one it was compared with are always kept).

**Spotlight.** `~/Library/Application Support/Likely` and `~/Library/Logs/Likely` are kept out of the
Spotlight index, so eval reports, test cases and the log never turn up in an agent's `mdfind` (an eval's
expected answer leaking into the search it tests). A `.metadata_never_index` file no longer does this
for an ordinary folder: on macOS 26 files under a folder holding one were still returned by `mdfind`.
Spotlight still skips folders whose name ends in `.noindex`, so on launch Likely moves each folder to
`<name>.noindex` and leaves a link with the old name; every path above keeps working. (The marker file is
written as well, for macOS versions that honor it.) Nothing is written to the log until both moves are
done, and if an earlier version did split a folder (both names real folders), the old one's contents are
merged into the `.noindex` one and it's replaced by the link.

**Other apps' private data.** The agents are also kept out of macOS's protected stores (Photos libraries,
Mail, Messages, Contacts & Calendars, Notes, Safari, other apps' containers) unless you turn one on in
Settings → Permissions → Private data, or allow it for a tool that needs it. Stores only Full Disk Access
opens (call history, the TCC database, Biome, iPhone backups, cookies, the data-protection keychain, …)
are always denied, even with every area on. See [TOOLS.md](TOOLS.md#private-data-needs), which also lists
what's left for Codex.

## Protected settings

The settings that decide what Likely runs (the agent, the models, Claude Code's location, the prompt,
which tools you approved, and "Allow command-line test runs") live in Likely's preferences, which any
program running as you can change (`defaults write`, or `-key value` arguments when launching the app). In
builds with a provisioning profile (official releases), each of them is stored with an HMAC-SHA256 keyed
from the data key in the data-protection keychain (see Encryption), which only Likely's own builds can
read. A value changed any other way has no valid HMAC: Likely ignores it, uses the default (Claude Code
as the agent, the default prompt, no approvals, command-line runs off), and logs the setting's name.

Settings shows each ignored setting, and why: changed outside this copy of Likely (its HMAC doesn't
match, e.g. another program, or an older version of Likely after a downgrade), or saved without an HMAC
(by a build that can't protect settings, such as one built from source without a provisioning profile,
or by another program). **Keep This Value…** shows the value first (for the prompt, its length and the
full text; for tool approvals, each tool's commands) and seals it only when you confirm; **Use Default**
removes it. Until you choose, the prompt editor shows this notice instead of the default, and saves
nothing, so it can't overwrite your saved prompt; tool approvals can't be changed either (a change would
replace the saved ones).

The first launch of a version with this protection seals the values already saved in Likely's own
preferences (never launch arguments or the global domain, and never "Allow command-line test runs",
which is new with the protection), once, and records that in the keychain, where nothing outside Likely
can undo it. A value that can't be sealed is skipped and stays ignored. Until that's done (the keychain
doesn't answer yet, e.g. before the first unlock), unsealed values count as "couldn't check" rather than
as changed outside Likely: Likely uses the defaults for now and tries again when a setting is read (at
most every 30 seconds), when the Mac wakes, and from **Try Again** in Settings. While the keychain doesn't
answer, these settings fall back to their defaults too.

Builds without a provisioning profile have no data key, so these settings are stored plainly, as other
preferences are, and can be changed from outside Likely. When such a build saves one of them, it removes
the HMAC an official build stored, so the official build later shows the value as "saved without an
HMAC" (Keep This Value… applies) rather than as tampered.

**Run Tests in Settings.** With "Allow command-line test runs" off, only Settings → Tests → Run Tests can
start `Likely --eval`. Before it starts the run, Likely stores a one-time token record (a SHA-256 of a
random token, and an expiry 60 seconds later), sealed with the same HMAC, and gives the token itself only
to the process it starts, in its environment. The run checks the record's HMAC, the expiry and the token,
deletes the record, and removes the token from its environment before starting any agent. Something that
can write Likely's preferences can't make a record that verifies, and reading the record doesn't reveal
the token. Known limitation: a program running as you that copies a sealed record and reads the token
from the run's environment within those 60 seconds could put the record back and use the token once
more; a generation counter to prevent that is planned.

## The log

`~/Library/Logs/Likely/likely.log` (Settings → General → Troubleshooting → Open Log) is for finding out why
a picker wasn't detected or a search went wrong. By default it records:

- events and states: a picker opened or closed and in which app, how it was detected, the agent
  starting, finishing or failing, a copy made or skipped and why, license and update checks;
- timings and counts: how long recent files took, how many files were found or picked, how long what you
  typed was, the cost of a search;
- non-identifying metadata: app names, agent and model names, accessibility roles and identifiers, window
  sizes and positions, process IDs, error domains and codes.

It doesn't record what you typed, window titles (email subjects, document names), file paths and names,
what the agent wrote (its STATUS and FILE lines, answers, error output), or the prompt. Where one of those
belongs in a line, the log has a short code instead, plus the extension for a file:

```
[picker] OPENED in Safari via ax:AXWindowCreated frame=440,210 800x500 title=<#9c41d2e7>
[feedback] request: 18 chars <#3f0a7e11>
[likely] added <#b81c55a0 .pdf>
[likely] skip <#20e9af3c .env> (hidden file or folder)
[picker] picked 1 (confirmed with Return): [<#b81c55a0 .pdf>]
[claude] result is_error=true kind=rateLimit subtype=success turns=1 cost=0.0123 result=<#5d02aa94>
```

The same value gets the same code within one run of Likely, so lines about the same file can be followed.
The codes are keyed with a random value that changes at every launch and is never written down, so they
can't be checked against guesses.

Release builds write nothing to the macOS unified log: any process running as you can read that with
`log show`, outside the protection of `~/Library/Logs/Likely`. (Dev builds copy each line there with the
message marked private.)

**Log details for troubleshooting** (Settings → General → Troubleshooting) also writes every line that
has one of those values, in full, to a second file, `likely-details.log`; logs every accessibility event and
window; and keeps the agent's transcript of the last search (`…/Likely/transcripts/last-run.jsonl`). Turn it
on to reproduce a problem and send the detailed log (Open Log shows it while details are on) with a bug
report. It turns itself off after 24 hours or when you quit Likely, whichever comes first, and at the next
launch if Likely didn't quit normally; `likely-details.log` and the transcript are deleted then. Only
turning it on in Settings counts: the end time is kept in Likely's memory, and the copy in its preferences
only shows it in Settings, so a changed preferences file can't turn details on (the search agents can't
write Likely's preferences anyway; checked for Codex's read-only sandbox too). An end time more than 24
hours away (the clock was set back) counts as off. Dev builds (`./build.sh`) always log details.

**Upgrading.** Versions before this one wrote what you typed, window titles and file paths into the log.
Before writing the first line, Likely checks the format recorded in the log folder (`log-format`); if
it's older, it deletes `likely.log` and any rotated `likely.log.*` copies, and notes it in the new log.

For developers: a log line is a `LogMessage`, whose literal type is `StaticString`, so a `String` can only
go into it marked: `sensitive:` (private), `path:` (private, keeps the extension), `error:` (domain and
code; the description is private), `public:` (constants only) or `meta:` (non-identifying runtime
metadata, such as an app or model name). Bare interpolations compile only for numbers, booleans and
`LogSafe` types. `LogPrivacySourceTests` keeps every `meta:` use (by its source line) and every `LogSafe`
type to a reviewed list, so a new one fails `swift test` until someone checks it (see
`Sources/LikelyStorage/LogPrivacy.swift`, and `scripts/check-log-privacy.sh`).

### Why tools.json and cases.jsonl stay plaintext

You edit both, often with your own coding agent ("add an rclip tool to Likely", "fix this test case").
Encrypting them would make that impossible. They're protected instead by the sandbox (the search agents
can't read or change them), by owner-only permissions, and for tools.json by the Approve step: a tool
changed outside Likely's Settings does nothing until you approve it there.

## Deleting it

- **Search history:** Settings → History → Clear History…, or delete the `History` folder.
- **Tests:** Settings → Tests, or delete `…/Likely/evals`.
- **Log:** Settings → General → Clear Log (both files), or delete `~/Library/Logs/Likely`.
- **Everything:** quit Likely, then delete `~/Library/Application Support/Likely`,
  `~/Library/Application Support/Likely.noindex`, `~/Library/Logs/Likely`, `~/Library/Logs/Likely.noindex`
  and `~/Library/Preferences/inc.synth.likely.plist`. Without the data, the key left in the keychain
  protects nothing. (Keychain Access doesn't show data-protection keychain items. Pre-release test builds
  kept a "Likely data key" in the login keychain; delete it in Keychain Access if you have one.)
