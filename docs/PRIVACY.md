# Your data

Likely keeps everything on this Mac. Nothing listed here is uploaded by Likely itself. The search
agent you choose does send your query, the screenshot (if you turned that on) and what it reads while
searching to its model provider; that's how the search works.

## What Likely stores, and where

| What | Where | Protection |
| --- | --- | --- |
| Search history (what you typed, the app, suggestions, the pick; last 500) | `~/Library/Application Support/Likely/History/history.enc.jsonl` (encrypted), or `history.jsonl` in builds without encryption | Encrypted (official releases), owner-only, agents can't read it |
| Your test cases and drafts | `…/Likely/evals/cases.jsonl`, `drafts.jsonl` | Plaintext (see below), owner-only, agents can't read them |
| Screenshots saved with tests | `…/Likely/evals/screenshots/<id>.png.enc`, or `<id>.png` in builds without encryption | Encrypted (official releases), owner-only, agents can't read them |
| Eval runs (results, reports, transcripts) | `…/Likely/evals/runs/` (dev builds only) | Owner-only, agents can't read them (a running case reads only its own folder) |
| Your extra agent tools | `…/Likely/tools.json` | Plaintext (see below), owner-only, agents can't read it |
| The screenshot sent with a search | `…/Likely/run/context-<id>.png` | Owner-only; only on disk while the agent works on a turn (see below) |
| Agent transcripts of the current search | `…/Likely/run/last-run.jsonl` | Owner-only, agents can't read it |
| Copies Likely made in the Likely folder (bookkeeping) | `…/Likely/likely-manifest.json` | Owner-only |
| Debug view screenshots | In memory only. Dev builds also write `…/Likely/debug/<id>.png` | Owner-only (dev builds) |
| Log | `~/Library/Logs/Likely/likely.log` | Owner-only, agents can't read it |
| Settings, tool approvals | `~/Library/Preferences/inc.synth.likely.plist` | Agents can't write them |
| Encryption key | Data-protection keychain, access group `<team id>.inc.synth.likely`, "Likely data key" (`inc.synth.likely.data-key`) | Only Likely can read it; this device only, never synced |

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
(the screenshot for this search, OpenCode's config, Gemini's settings, Hermes's helper), and the case's own
folder for an eval. Transcripts (`*.jsonl`) there stay unreadable. So a prompt-injected or curious agent
can't read your history, your tests and their expected answers, earlier eval reports, or the log.
tools.json needs no exception: the agents get your tools in their prompt.

**Encryption.** Encryption is on in official releases, and off in builds without a provisioning
profile (`./build.sh` by default). Settings → History shows which: "Encryption: on", or "Encryption: off
in this build (no provisioning profile)" with a link to [BUILDING.md](BUILDING.md), which explains how to
turn it on with your own Apple team.

With encryption on, search history and screenshots saved with tests are encrypted with AES-256-GCM. The
random key is kept in the data-protection keychain, in Likely's own access group
(`<team id>.inc.synth.likely`). Only apps signed by Likely's team with that group in their entitlements
can read it, and no other app can be given access to it. It's readable after first unlock, on this
device only, and not synced. Likely finds its team and access group in its own code signature at
launch; nothing is hard-coded. Reading the key never shows a prompt. If it can't be read, Likely
reports that instead, and doesn't make a new key over it.

History is encrypted line by line (`lk1:<key id>:<base64>` per line) rather than as one blob, so it
keeps the guarantees it has in plaintext:
- a line that can't be opened is skipped and kept in place rather than breaking the file;
- a file that can't be read is never overwritten;
- lines are split on `\n` only.

The cost is that the number of entries and their approximate sizes are visible.

Encrypted and plaintext history are kept in separate files (`history.enc.jsonl`, `history.jsonl`). A
build with encryption encrypts plaintext history and saved test screenshots on launch, then deletes the
plaintext. A build without encryption leaves encrypted data alone: Settings → History says "History is
encrypted by another build of Likely", it keeps its own history unencrypted, and an encrypted test
screenshot shows as unreadable. Nothing is wiped.

Without encryption, the data has every other protection here: owner-only files, the agents can't read
it, and it's kept out of Spotlight. There's deliberately no weaker fallback, such as a key file next to
the data, or the login keychain with its "wants to use your confidential information" prompts.

**Less on disk.** The screenshot sent with a search is written when you submit the search and deleted as
soon as the agent's turn finishes. Likely keeps it in memory while the picker is open, because a follow-up
("not these, the signed one") may need it: the agent may look again, and an agent restarted after a crash
gets it attached again. So it's written back just before each follow-up turn and deleted again after it,
and dropped from memory when the picker closes. Release builds keep debug-view screenshots in memory only,
and delete any `debug/*.png` older versions left.

**Spotlight.** `~/Library/Application Support/Likely` and `~/Library/Logs/Likely` are kept out of the
Spotlight index, so eval reports, test cases and the log never turn up in an agent's `mdfind` (an eval's
expected answer leaking into the search it tests). A `.metadata_never_index` file no longer does this
for an ordinary folder: on macOS 26 files under a folder holding one were still returned by `mdfind`.
Spotlight still skips folders whose name ends in `.noindex`, so on launch Likely moves each folder to
`<name>.noindex` and leaves a link with the old name; every path above keeps working. (The marker file is
written as well, for macOS versions that honor it.)

### Why tools.json and cases.jsonl stay plaintext

You edit both, often with your own coding agent ("add an rclip tool to Likely", "fix this test case").
Encrypting them would make that impossible. They're protected instead by the sandbox (the search agents
can't read or change them), by owner-only permissions, and for tools.json by the Approve step: a tool
changed outside Likely's Settings does nothing until you approve it there.

## Deleting it

- **Search history:** Settings → History → Clear History…, or delete the `History` folder.
- **Tests:** Settings → Evals, or delete `…/Likely/evals`.
- **Everything:** quit Likely, then delete `~/Library/Application Support/Likely`,
  `~/Library/Application Support/Likely.noindex`, `~/Library/Logs/Likely`, `~/Library/Logs/Likely.noindex`
  and `~/Library/Preferences/inc.synth.likely.plist`. Without the data, the key left in the keychain
  protects nothing. (Keychain Access doesn't show data-protection keychain items. Pre-release test builds
  kept a "Likely data key" in the login keychain; delete it in Keychain Access if you have one.)
