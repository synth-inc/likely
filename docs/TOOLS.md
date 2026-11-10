# Tools

Likely's search agent can only run a few read-only search commands (`mdfind`, `mdls`, `ls`, `grep`, `head`,
`stat`, plus each agent's own file reading). Tools let you give it more: any command-line program you
have installed, with instructions for when to use it. Settings → Tools lists the built-in ones under
"Built in" (from `AgentBuiltins`, the runners' own allowlists) below your tools.

Tools live in one file, the source of truth:

```
~/Library/Application Support/Likely/tools.json
```

Edit it in Settings → Tools, by hand, or let a coding agent do it (Settings → Tools → "Set up with your
coding agent" has a prompt to paste; it also tells the agent how to measure the tool with your tests). Likely watches the file and checks it again before each search. If
the file is missing, there are no extra tools; if it isn't valid JSON, Likely logs why
(`~/Library/Logs/Likely/likely.log`), shows it in the Tools tab and uses only the built-in commands.

**Approval.** Edits made in Settings → Tools apply right away. When tools.json changes any other way (a
coding agent, a script, an editor) and the commands or instructions of an enabled tool change, that tool
isn't used until you click **Approve** in Settings → Tools. The tab shows which tools changed and a short
diff of their commands; the menu bar icon gets a dot and its menu shows "Approve Tool Changes…" (plus a
notification, if Likely is allowed to post them). Likely stores a SHA-256 of each approved tool's commands,
instructions and `needs` in its preferences, which no agent can write. So a tool planted or edited outside
Likely can't quietly ask for your Mail: a changed `needs` waits for approval like a new command. While a
tool waits, its switch and its **Allow…** button are off: only Approve, which shows the whole change,
makes it usable. Switching a tool on or off never approves anything.

**Share what works.** Found a tool that improves your results? Post it in [Share your tools](https://github.com/synth-inc/likely/discussions/32): the tool, your `tools.json` entry, what it helps find, and your before-and-after test numbers. Please don't post your searches, file names or paths. The tools that work best for people will become Likely's defaults.

## Measure what a tool adds

Your saved tests (see [EVALS.md](EVALS.md)) tell you whether a tool actually helps:

1. **Save misses as tests.** When Likely doesn't find the file, click "Save as test" in the bar above the
   picker, or use **Make Eval** in Settings → History, so the search and the file you wanted become a test.
2. **Run the tests once** (Settings → Tests → Run Tests…, or the command below) to have a baseline.
3. **Add the tool** (or edit a tool's instructions, or the prompt), and **approve** it in Settings → Tools.
4. **Run them again.** The result compares itself with the previous run: how many pass now, which tests
   started or stopped passing, and "tools changed: +rclip". **Without your tools** (`--without-tools`) shows
   what all your tools add together.

A coding agent can do steps 2-4 for you: the "Set up with your coding agent" prompt in Settings → Tools
tells it to run

```sh
/Applications/Likely.app/Contents/MacOS/Likely --eval personal --json
```

before and after adding the tool and report the difference (`summary.passed`, `comparison.nowPassing`,
`comparison.toolsChanged`; field list and exit codes in [EVALS.md](EVALS.md#from-the-command-line-or-your-coding-agent)).
Settings → Tests shows the exact command for your copy of Likely, with **Copy Command** and **Copy for Coding
Agent**; turn on **Allow command-line test runs** there first (off by default; the command exits with status
4 until then). A tool the agent added waits for your Approve, and the run lists it under
`tools.pendingApproval` and doesn't use it until then: the agent can't approve it, and can't make the run
use anything but your approved tools, the agents Likely found and your saved prompt.

## Schema

```json
{
  "version": 1,
  "tools": [
    {
      "id": "rclip",
      "name": "Image search (rclip)",
      "enabled": true,
      "commands": ["cd", "rclip -n"],
      "instructions": "When the user wants an image, …",
      "setup": "brew install rclip …"
    }
  ]
}
```

| Field | Type | |
|---|---|---|
| `id` | string | Unique. Optional: derived from `name` if missing; duplicates get `-2`, `-3`, … |
| `name` | string | Required. Shown in Settings and in the agent's prompt. |
| `enabled` | bool | Optional, default `true`. |
| `commands` | [string] | Command prefixes the agent may run (a single string is accepted too). |
| `instructions` | string | Added to the agent's prompt: when to use the tool, the exact command line, what it prints. |
| `setup` | string | Optional. How it was installed and how to maintain it. Not sent to the agent. |
| `needs` | [string] | Optional. Private data areas the tool reads (see below): `photos`, `mail`, `messages`, `contacts`, `notes`, `safari`, `app-data`. |

## Private data (`needs`)

Search agents are kept out of macOS's protected stores by default (Settings → Permissions → Private
data, all off): Photos libraries (`~/Library/Photos`, `~/Pictures/Photos Library.photoslibrary` and any
`*.photoslibrary`), Mail, Messages, Contacts & Calendars (and Reminders), Notes, Safari, and other apps'
containers (`~/Library/Containers`, `~/Library/Group Containers`). Otherwise a search for a tax form that
walks through ~ ends with macOS asking whether "Likely" may access your Photos.

Each area also covers its own folders inside those containers, matched by name (for example
`com.apple.photoanalysisd`, `com.apple.MobileSMS.*`, `com.apple.mail.*`, `group.com.apple.contacts`,
`com.apple.Safari.*`, `group.com.apple.notes`). Turning Contacts on opens Contacts' containers even while
"Other apps' private data" is off; turning that one on doesn't open Mail's.

Some stores only Full Disk Access opens, and no area is about them: the TCC database, call history,
Knowledge and Biome activity, Suggestions, iPhone backups, Accounts, IdentityServices, HomeKit, Core
Spotlight's index, FaceTime, cookies and the data-protection keychain (`~/Library/Keychains/*/`). They're
always denied, so granting Likely Full Disk Access for Mail doesn't open them to the agents. Mail, Messages
and Safari themselves can only be read with Full Disk Access, which macOS never asks for: you add Likely
in System Settings → Privacy & Security, and the agents then get it too wherever the area is on.

Codex can't use patterns, so for Codex Likely lists the containers at each search, and finds Photos
libraries outside the default places in the background (the home folder 3 levels deep, outside
~/Library, and each local volume 2 levels deep). A library deeper than that, or added since the last
scan, isn't denied to Codex. Codex's `view_image` tool opens an image itself, outside its sandbox, so
it's turned off while Photos is off.

A tool that reads one of them declares it:

```json
{
  "id": "osxphotos",
  "name": "Photos library (osxphotos)",
  "enabled": true,
  "commands": ["osxphotos query --json"],
  "instructions": "When the user wants a photo from their Photos library, run `osxphotos query --json --description \"<words>\"` …",
  "setup": "pipx install osxphotos (or brew install osxphotos).",
  "needs": ["photos"]
}
```

- Turning on a tool whose areas are off asks "Photos library (osxphotos) needs access to your Photos.
  Allow?". Allow turns the area on and triggers macOS's own permission alert in one step (for Mail,
  Messages and Safari there's no alert: they need Full Disk Access, see above).
- Until every area it needs is on, the tool isn't used: its row says which area is off, with an
  **Allow…** button.
- An unknown id in `needs` makes the tool invalid (it's disabled, and the row says why).
- `needs` is part of what you approve (see Approval).

A bare array of tools (without the `{"tools": …}` wrapper) is also accepted. Entries that can't be read
(not an object, no name) are skipped and listed in the Tools tab; the rest still load.

## Rules

The agent runs these commands **unattended**, without asking you. Only add read-only commands.

Likely's checks catch mistakes; they can't prove a command is read-only. The guarantee is the sandbox:
while any tool is on, every agent runs where it can't write outside its own state (see below), and no
agent can ever write Likely's own folder (`~/Library/Application Support/Likely`, including tools.json) or
its preferences.

- **Prefix matching.** Each entry in `commands` is matched against the start of the command line:
  `rclip -n` allows `rclip -n -t 20 "a red car"` but not `rclip "a red car"`. Put flags that keep the
  tool read-only into the prefix.
- **Allowed characters only:** letters A-Z and a-z, digits, spaces and `. _ / ~ = : + @ % -`. Everything
  else is rejected, including quotes, commas (Gemini splits its allowlist on them), `?` `*` `[ ]` `{ }`
  (wildcards for OpenCode and the shell), `; | & > < $` and backticks, newlines and tabs. (The *agent*
  may still write `cd ~ && rclip …`: each part is checked separately.)
- **Blocked first words** (after any directory, case-insensitive), because they can write, reach the
  network, or run other code directly, through a flag (`rg --pre`, `find -exec`, `awk system()`) or by
  wrapping another command: `rm`, `rmdir`, `mv`, `cp`, `dd`, `ln`, `tee`, `truncate`, `shred`, `mkdir`,
  `touch`, `install`, `ditto`, `xattr`, `sudo`, `su`, `chmod`, `chown`, `chflags`, `curl`, `wget`, `ssh`,
  `scp`, `sftp`, `ftp`, `rsync`, `nc`, `ncat`, `telnet`, shells (`sh`, `bash`, `zsh`, `fish`, `dash`, `ksh`,
  `csh`, `tcsh`), interpreters (`python*`, `perl*`, `ruby*`, `node`, `swift`), `osascript`, `env`, `xargs`,
  `eval`, `exec`, `nohup`, `command`, `arch`, `nice`, `time`, `timeout`, `script`, `screen`, `tmux`, `at`,
  `crontab`, `find`, `awk`, `gawk`, `sed`, `rg`, `sort`, `file`, `git`, `make`, `npm`, `npx`, `pip*`, `brew`,
  `tar`, `zip`, `unzip`, `sqlite3`, `exiftool`, `plutil`, `defaults`, `security`, `open`, `kill`, `killall`,
  `pkill`, `launchctl`, `pbcopy`, `say`.
- **No empty commands.**
- **`cd`** only for tools that search the current folder and don't read config or plugins from the
  working directory (the agent runs `cd ~ && <tool> …`, so a config file in your home folder would apply).

A tool that breaks a rule is still saved, but turned off, and the Tools tab says why. The rules live in
`ToolValidator` (`Sources/LikelyTools/ToolValidator.swift`); the setup prompt is generated from it.

The command must be found on the agent's PATH: the agent's own folder, `/opt/homebrew/bin`,
`/usr/local/bin`, `~/.local/bin`, `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, then Likely's inherited PATH.
The **Test** button in the Tools tab checks this.

## Turning built-in tools off

Each built-in tool has a toggle (on by default), so you can compare search speed without one. The setting is
per agent (`disabledBuiltinTools.<agentID>` in Likely's preferences, which agents can't write); "Reset to
Defaults" turns them all back on. Your tools are never affected. What turning one off does:

- **Claude Code**: `Read`, `Glob` and `Grep` are left out of `--tools` (the model never sees them) and passed
  to `--disallowedTools`. A command (`mdfind`, `ls`, …) is left out of `--allowedTools`; Claude runs in
  `dontAsk` mode, so it's refused if tried. It isn't denied outright, so a tool of yours with the same prefix
  still works. With no command left (and no tools of yours), Bash is left out of `--tools` too.
- **Gemini CLI**: `read_file`/`list_directory` leave `tools.core` and go to `tools.exclude`; commands leave
  `--allowed-tools`. With no command left, `run_shell_command` is removed as well.
- **OpenCode**: the tool or command is no longer allowed in `OPENCODE_PERMISSION`, so the leading `"*": "deny"`
  applies (which also hides a tool). Its `grep` covers both the grep tool and the command. With no command
  left, `bash` is denied entirely.
- **Hermes**: the toolset (`terminal`, `file`, `vision`) is left out of `-t`. With all three off it gets `-t
  todo`, since an empty `-t` would mean Hermes' default (much larger) set.
- **Codex** has no per-tool list; its row is informational.

The search prompt then names the tools that are off ("Unavailable tools … Don't try them") and, in the default
template, drops the hints that use them (the `mdfind` examples, the `ls -lt` recent-files hint). Settings warns
when nothing that finds files by name is left (e.g. `mdfind` and `Glob` both off for Claude), but allows it.

## How each agent applies tools

Every enabled, valid tool's instructions go into the prompt under "Extra tools you can use" (at
`{{tools}}` if your prompt template has it, otherwise at the end). Its commands are allowlisted per agent:

| Agent | Allowlist | Notes |
|---|---|---|
| Claude Code | `--allowedTools Bash(<prefix>:*)` | While any tool is on, runs in a sandbox that only allows writes to its own state (`~/.claude`, `~/.claude.json*`, its caches) and temp folders, HTTPS only. `cd` only works into folders Claude was given (`--add-dir`: home and your search folders). |
| Gemini CLI | `--allowed-tools=run_shell_command(<prefix>)` | While any tool is on, runs in a sandbox that only allows writes to `~/.gemini` and temp folders, HTTPS only. Each segment of a `&&` chain must match. |
| OpenCode | bash permissions `"<prefix>": "allow"`, `"<prefix> *": "allow"` | Added before the `find -exec/-delete` denials, which still win. Runs in Likely's write-blocking sandbox. |
| Codex | none | Codex can't limit commands; it relies on its read-only sandbox (no writes, no network). Tools reach it through the prompt only. |
| Hermes | none | Hermes can't limit commands either; it relies on Likely's write-blocking sandbox (HTTPS only). Tools reach it through the prompt only. |

So with tools on, a tool that needs to write (a cache, an index) or, under Codex, reach the network fails
at run time, whichever agent runs it. Do that work in the tool's setup, outside Likely. (`rclip -n` was
checked to work this way under Claude Code, Gemini CLI and OpenCode.)

Tests (`--eval`, Settings → Tests) run your personal cases with your tools, as the app does (or without them,
`--without-tools`), and the public fixture suite (dev builds) without them unless you pass `--with-tools`;
each run records which tools it used. See
[EVALS.md](EVALS.md#your-tools).

## Worked example: image search with rclip

Settings → Tools (also menu bar → Improve Results…) always lists **Photo search (rclip)**. Without rclip
it offers **Set Up…**, a prompt for your coding agent that does the steps below. With rclip installed it's
a toggle that writes the entry below. Once tools.json has an rclip entry, it's an ordinary tool.

[rclip](https://github.com/yurijmikhalevich/rclip) searches images by what they show, using a local CLIP
index.

1. Install it: `brew install rclip` (or `pipx install rclip`).
2. Build the index. rclip has no index-only flag (checked with rclip 4.1.1); any search without `-n`
   updates the index of the current folder first, so run a throwaway search from your home folder:

   ```sh
   cd ~ && rclip -t 1 --exclude-dir Library --exclude-dir node_modules --exclude-dir .git photo
   ```

   The first run takes a while. Re-run it now and then to pick up new images. (`--exclude-dir` replaces
   rclip's default exclusions, so the defaults worth keeping are listed again.)
3. Check that searching works without re-indexing:

   ```sh
   cd ~ && rclip -n -t 5 "a screenshot of an app window"
   ```

4. Add the tool to `tools.json` (or turn on the Photo search row; edits made outside Likely need your
   Approve in Settings → Tools):

   ```json
   {
     "version": 1,
     "tools": [
       {
         "id": "rclip",
         "name": "Image search (rclip)",
         "enabled": true,
         "commands": ["cd", "rclip -n"],
         "instructions": "When the user wants an image, rewrite the request as a short visual description of what the picture shows (e.g. \"the receipt from dinner\" → \"a photo of a paper restaurant receipt\") and run `cd ~ && rclip -n -t 20 \"<description>\"`. It prints a score and a path per line, best first.",
         "setup": "brew install rclip (or pipx install rclip). Build the index, and re-run it to pick up new images: cd ~ && rclip -t 1 --exclude-dir Library --exclude-dir node_modules --exclude-dir .git photo"
       }
     ]
   }
   ```

Why these commands: `rclip -n` searches without updating the index (without `-n`, rclip would re-index,
which is slow and writes). `cd` is there because rclip searches the current folder, so the agent runs
`cd ~ && rclip -n …`. The instructions ask for a visual description because CLIP matches what is in the
picture, not words like "my" or "the one from".

The agent then sees:

```
Extra tools you can use (installed by the user; run them like the search commands above):
- Image search (rclip) (allowed: `cd`, `rclip -n`): When the user wants an image, rewrite the request as a short visual description of what the picture shows (e.g. "the receipt from dinner" → "a photo of a paper restaurant receipt") and run `cd ~ && rclip -n -t 20 "<description>"`. It prints a score and a path per line, best first.
```
