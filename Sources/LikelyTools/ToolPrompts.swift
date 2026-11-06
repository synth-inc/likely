import Foundation

public enum ToolPrompts {
    /// The "Extra tools" section of the search agent's prompt, or "" when no tool is active.
    public static func section(for tools: [CustomTool]) -> String {
        let active = tools.filter(\.isActive)
        guard !active.isEmpty else { return "" }
        var lines = ["Extra tools you can use (installed by the user; run them like the search commands above):"]
        for tool in active {
            let commands = tool.cleanedCommands.map { "`\($0)`" }.joined(separator: ", ")
            let instructions = tool.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n  ")
            lines.append("- \(tool.name) (allowed: \(commands))" + (instructions.isEmpty ? "" : ": " + instructions))
        }
        return lines.joined(separator: "\n")
    }

    /// Where tools.json lives, with ~ for the home folder.
    public static let displayPath = "~/Library/Application Support/Likely/tools.json"

    /// The example used in the setup prompt and docs/TOOLS.md: image search with rclip.
    public static let example = CustomTool(
        id: "rclip",
        name: "Image search (rclip)",
        enabled: true,
        commands: ["cd", "rclip -n"],
        instructions: """
        When the user wants an image, rewrite the request as a short visual description of what the picture shows \
        (e.g. "the receipt from dinner" → "a photo of a paper restaurant receipt") and run `cd ~ && rclip -n -t 20 "<description>"`. \
        It prints a score and a path per line, best first.
        """,
        setup: "brew install rclip (or pipx install rclip). Build the index, and re-run it to pick up new images: cd ~ && rclip -t 1 --exclude-dir Library --exclude-dir node_modules --exclude-dir .git photo")

    public static var exampleJSON: String {
        let data = (try? ToolsFile(tools: [example]).encoded()) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prompt the user pastes into their own coding agent to add a tool for them. Built from the
    /// validator's constants so it states exactly the rules Likely enforces.
    public static var setupPrompt: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = AgentPath.directories(agentExecutable: nil, inherited: nil, home: home)
            .map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
            .joined(separator: ", ")
        return """
        I use Likely, a macOS menu bar app that helps in file pickers. When I open an Open dialog, Likely sends my request \
        to a headless coding agent (Claude Code, Codex, Gemini CLI, OpenCode or Hermes), which searches my Mac with \
        read-only commands like mdfind, ls and grep and returns the files I probably want. I want to give that search \
        agent an extra command-line tool. Please set it up.

        Likely reads extra tools from this file (create it if it doesn't exist; keep any tools already in it):
        \(displayPath)

        Schema, with an example:
        \(exampleJSON)

        Fields:
        - id: short unique identifier (lowercase letters, digits, dashes).
        - name: shown in Likely's Settings and in the search agent's prompt.
        - enabled: true or false.
        - commands: command prefixes the search agent may run. Each one is matched against the start of the command \
        line, so "rclip -n" allows `rclip -n -t 20 "a red car"` but not `rclip "a red car"`. Include fixed flags that \
        keep the tool read-only. If the tool works on the current folder, add "cd" too; the agent then runs `cd ~ && <tool> …`.
        - instructions: added to the search agent's prompt. Say when to use the tool, the exact command line to run \
        and what the output looks like, in a few sentences.
        - setup (optional): how the tool was installed and how to maintain it (e.g. re-indexing). Not shown to the search agent.

        Rules (Likely checks them and disables a tool that breaks one):
        - The search agent runs these commands unattended, without asking me, so allow only read-only commands: \
        nothing that changes, moves or deletes files, sends data anywhere, or runs other programs.
        - No shell metacharacters or quotes in a command: \(ToolValidator.forbiddenCharactersDescription)
        - None of these as the first word: \(ToolValidator.blockedFirstWords.joined(separator: ", "))
        - No empty commands.

        Likely notices changes to tools.json and uses them from the next search; no restart needed. Its Settings → \
        Tools tab shows each tool's status and why one was disabled.

        Before adding the tool:
        1. Install it (Homebrew or pipx preferred) and do any one-time setup it needs, such as building an index.
        2. Run the exact command from your instructions in Terminal and check that it prints useful results. The \
        search agent's PATH is \(path), so the tool must be found in one of those.
        3. Add the entry, check that the file is valid JSON (e.g. `python3 -m json.tool ~/"Library/Application Support/Likely/tools.json"`), and tell me \
        what you added.

        What I want:\u{20}
        """
    }
}
