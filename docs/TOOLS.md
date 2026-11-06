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
coding agent" has a prompt to paste). Likely watches the file and checks it again before each search,
so changes apply from the next search without a restart. If the file is missing, there are no extra
tools; if it isn't valid JSON, Likely logs why (`~/Library/Logs/Likely/likely.log`), shows it in the
Tools tab and uses only the built-in commands.

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

A bare array of tools (without the `{"tools": …}` wrapper) is also accepted. Entries that can't be read
(not an object, no name) are skipped and listed in the Tools tab; the rest still load.

## Rules

The agent runs these commands **unattended**, without asking you. Only add read-only commands.

- **Prefix matching.** Each entry in `commands` is matched against the start of the command line:
  `rclip -n` allows `rclip -n -t 20 "a red car"` but not `rclip "a red car"`. Put flags that keep the
  tool read-only into the prefix.
- **No shell metacharacters or quotes:** `;` `|` `&` `>` `<` `$` `` ` `` `(` `)` `*` `\` `"` `'`, newlines,
  carriage returns or tabs. They would let a prefix chain or redirect commands, or break an agent's
  permission syntax. (The *agent* may still write `cd ~ && rclip …`: each part is checked separately.)
- **Blocked first words** (after any directory, case-insensitive): `rm`, `rmdir`, `mv`, `cp`, `dd`, `ln`,
  `tee`, `truncate`, `shred`, `sudo`, `su`, `chmod`, `chown`, `chflags`, `curl`, `wget`, `ssh`, `scp`,
  `rsync`, shells (`sh`, `bash`, `zsh`, `fish`, `dash`, `ksh`, `csh`, `tcsh`), interpreters (`python*`,
  `perl*`, `ruby*`, `node`), `osascript`, `env`, `xargs`, `eval`, `exec`, `nohup`, `command`, `open`, `kill`,
  `killall`, `pkill`, `launchctl`.
- **No empty commands.**

A tool that breaks a rule is still saved, but turned off, and the Tools tab says why. The list in code is
`ToolValidator` (`Sources/LikelyTools/ToolValidator.swift`); the setup prompt is generated from it.

The command must be found on the agent's PATH: the agent's own folder, `/opt/homebrew/bin`,
`/usr/local/bin`, `~/.local/bin`, `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, then Likely's inherited PATH.
The **Test** button in the Tools tab checks this.

## How each agent applies tools

Every enabled, valid tool's instructions go into the prompt under "Extra tools you can use" (at
`{{tools}}` if your prompt template has it, otherwise at the end). Its commands are allowlisted per agent:

| Agent | Allowlist | Notes |
|---|---|---|
| Claude Code | `--allowedTools Bash(<prefix>:*)` | `cd` only works into folders Claude was given (`--add-dir`: home and your search folders). |
| Gemini CLI | `--allowed-tools=run_shell_command(<prefix>)` | Each segment of a `&&` chain must match. |
| OpenCode | bash permissions `"<prefix>": "allow"`, `"<prefix> *": "allow"` | Added before the `find -exec/-delete` denials, which still win. Runs in Likely's write-blocking sandbox. |
| Codex | none | Codex has no per-command allowlist: it runs any command, inside its read-only sandbox (no writes, no network). Tools reach it through the prompt only. |
| Hermes | none | Hermes has no allowlist either; it runs any command inside Likely's write-blocking sandbox (HTTPS only). Tools reach it through the prompt only. |

Under OpenCode, Hermes and Codex, a tool that needs to write (a cache, an index) or, under Codex, reach
the network fails at run time. Do that work in the tool's setup, outside Likely.

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

4. Add the tool to `tools.json`:

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
