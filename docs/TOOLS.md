# Tools

Likely's search agent can only run a few read-only search commands (`mdfind`, `mdls`, `ls`, `grep`, `head`,
`stat`, plus each agent's own file reading). Tools let you give it more: any command-line program you
have installed, with instructions for when to use it. Settings → Tools lists the built-in ones under
"Built in" (always on, read from the runners' own allowlists) below your tools.

Tools live in one file, the source of truth:

```
~/Library/Application Support/Likely/tools.json
```

Edit it in Settings → Tools, by hand, or let a coding agent do it (Settings → Tools → "Set up with your
coding agent" has a prompt to paste). Likely watches the file and checks it again before each search. If
the file is missing, there are no extra tools; if it isn't valid JSON, Likely logs why
(`~/Library/Logs/Likely/likely.log`), shows it in the Tools tab and uses only the built-in commands.

**Approval.** Edits made in Settings → Tools apply right away. When tools.json changes any other way (a
coding agent, a script, an editor) and the commands or instructions of an enabled tool change, that tool
isn't used until you click **Approve** in Settings → Tools. The tab shows which tools changed and a short
diff of their commands; the menu bar icon gets a dot and its menu shows "Approve Tool Changes…" (plus a
notification, if Likely is allowed to post them). Likely stores a SHA-256 of each approved tool's commands,
instructions and `needs` in its preferences, which no agent can write. So a tool planted or edited outside
Likely can't quietly ask for your Mail: a changed `needs` waits for approval like a new command.

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
| `needs` | [string] | Optional. Private data areas the tool reads (see below): `photos`, `mail`, `messages`, `contacts`, `safari`, `app-data`. |

## Private data (`needs`)

Search agents are kept out of macOS's protected stores by default (Settings → Permissions → Private
data, all off): Photos libraries (`~/Library/Photos`, `~/Pictures/Photos Library.photoslibrary` and any
`*.photoslibrary`), Mail, Messages, Contacts & Calendars (and Reminders), Safari, and other apps'
containers (`~/Library/Containers`, `~/Library/Group Containers`). Otherwise a search for a tax form that
walks through ~ ends with macOS asking whether "Likely" may access your Photos.

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
  Allow?". Allow turns the area on and triggers macOS's own permission alert in one step.
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
