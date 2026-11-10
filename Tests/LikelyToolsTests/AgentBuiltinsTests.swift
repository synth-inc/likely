import XCTest
@testable import LikelyTools

final class AgentBuiltinsTests: XCTestCase {
    // MARK: Claude

    func testClaudeDefaultsUnchanged() {
        let config = AgentBuiltins.claude(disabled: [], extra: [])
        XCTAssertEqual(config.tools, ["Read", "Glob", "Grep", "Bash"])
        XCTAssertEqual(config.allowed, ["Read", "Glob", "Grep", "Bash(ls:*)", "Bash(mdfind:*)", "Bash(mdls:*)",
                                        "Bash(head:*)", "Bash(stat:*)", "Bash(grep:*)"])
        XCTAssertEqual(config.disallowed, [])
    }

    func testClaudeDisabledFileToolIsRemovedAndDenied() {
        let config = AgentBuiltins.claude(disabled: ["Glob", "mdfind"], extra: ["rclip -n"])
        XCTAssertEqual(config.tools, ["Read", "Grep", "Bash"])
        XCTAssertFalse(config.allowed.contains("Glob"))
        XCTAssertFalse(config.allowed.contains("Bash(mdfind:*)"))
        XCTAssertTrue(config.allowed.contains("Bash(rclip -n:*)"))   // the user's tools are unaffected
        XCTAssertEqual(config.disallowed, ["Glob"])                     // commands aren't denied outright
    }

    func testClaudeDropsBashOnlyWhenNoCommandIsLeft() {
        let allCommands = Set(AgentBuiltins.claudeCommands)
        XCTAssertEqual(AgentBuiltins.claude(disabled: allCommands, extra: []).tools, ["Read", "Glob", "Grep"])
        let withUserTool = AgentBuiltins.claude(disabled: allCommands, extra: ["rclip -n"])
        XCTAssertEqual(withUserTool.tools, ["Read", "Glob", "Grep", "Bash"])
        XCTAssertEqual(withUserTool.allowed, ["Read", "Glob", "Grep", "Bash(rclip -n:*)"])
        // An invalid user prefix doesn't bring Bash back.
        XCTAssertEqual(AgentBuiltins.claude(disabled: allCommands, extra: ["c?rl"]).tools, ["Read", "Glob", "Grep"])

        let nothing = AgentBuiltins.claude(disabled: Set(AgentBuiltins.names(for: "claude")), extra: [])
        XCTAssertEqual(nothing.tools, [])
        XCTAssertEqual(nothing.allowed, [])
        XCTAssertEqual(nothing.disallowed, ["Read", "Glob", "Grep"])
    }

    // MARK: Gemini

    func testGeminiDefaultsUnchanged() throws {
        let config = AgentBuiltins.gemini(disabled: [], extra: [])
        XCTAssertEqual(config.core, ["read_file", "list_directory", "run_shell_command"])
        XCTAssertEqual(config.exclude, [])
        XCTAssertEqual(config.allowedToolsArgument, "--allowed-tools=" + ["mdfind", "mdls", "ls", "grep", "head", "stat"]
            .map { "run_shell_command(\($0))" }.joined(separator: ","))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: AgentBuiltins.geminiSettings(config)) as? [String: Any])
        XCTAssertEqual((json["tools"] as? [String: Any])?["core"] as? [String], config.core)
    }

    func testGeminiDisabled() throws {
        let config = AgentBuiltins.gemini(disabled: ["list_directory", "mdfind", "ls"], extra: ["rclip -n"])
        XCTAssertEqual(config.core, ["read_file", "run_shell_command"])
        XCTAssertEqual(config.exclude, ["list_directory"])
        XCTAssertEqual(config.allowedToolsArgument,
                       "--allowed-tools=run_shell_command(mdls),run_shell_command(grep),run_shell_command(head),run_shell_command(stat),run_shell_command(rclip -n)")
        let tools = try XCTUnwrap((JSONSerialization.jsonObject(with: AgentBuiltins.geminiSettings(config)) as? [String: Any])?["tools"] as? [String: Any])
        XCTAssertEqual(tools["exclude"] as? [String], ["list_directory"])
    }

    func testGeminiNoCommandsRemovesShell() {
        let config = AgentBuiltins.gemini(disabled: Set(AgentBuiltins.geminiCommands), extra: [])
        XCTAssertEqual(config.core, ["read_file", "list_directory"])
        XCTAssertEqual(config.exclude, ["run_shell_command"])
        XCTAssertNil(config.allowedToolsArgument)
    }

    // MARK: OpenCode

    func testOpenCodeDefaultsUnchanged() {
        XCTAssertEqual(AgentBuiltins.openCodePermission(disabled: [], extra: []),
                       ToolPermissions.openCodePermission(fileTools: AgentBuiltins.openCodeFileTools, bashAllowed: AgentBuiltins.openCodeBashAllowed,
                                                          bashDenied: AgentBuiltins.openCodeBashDenied, extra: []))
    }

    func testOpenCodeDisabled() throws {
        let json = AgentBuiltins.openCodePermission(disabled: ["glob", "ls", "mdfind"], extra: ["rclip -n"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(object["glob"])                       // falls to "*": "deny"
        XCTAssertEqual(object["read"] as? String, "allow")
        XCTAssertEqual(object["external_directory"] as? String, "allow")
        let bash = try XCTUnwrap(object["bash"] as? [String: String])
        XCTAssertNil(bash["ls"])
        XCTAssertNil(bash["ls *"])
        XCTAssertNil(bash["mdfind *"])
        XCTAssertEqual(bash["find *"], "allow")
        XCTAssertEqual(bash["rclip -n *"], "allow")
        XCTAssertEqual(bash["find *-exec*"], "deny")
    }

    func testOpenCodeGrepCoversToolAndCommand() throws {
        let json = AgentBuiltins.openCodePermission(disabled: ["grep"], extra: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(object["grep"])
        XCTAssertNil((object["bash"] as? [String: String])?["grep *"])
        XCTAssertEqual(AgentBuiltins.names(for: "opencode").filter { $0 == "grep" }.count, 1)
    }

    func testOpenCodeNoCommandsDeniesBash() throws {
        let commands = Set(AgentBuiltins.openCodeBashAllowed.map(AgentBuiltins.openCodeCommand))
        let json = AgentBuiltins.openCodePermission(disabled: commands, extra: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["bash"] as? String, "deny")
        // A user tool keeps bash, with only its own commands allowed.
        let withTool = AgentBuiltins.openCodePermission(disabled: commands, extra: ["rclip -n"])
        XCTAssertTrue(withTool.contains(#""bash":{"*":"deny","rclip -n":"allow","rclip -n *":"allow""#), withTool)
    }

    // MARK: Hermes and Codex

    func testHermesToolsets() {
        XCTAssertEqual(AgentBuiltins.hermesToolsets(disabled: []), ["terminal", "file", "vision"])
        XCTAssertEqual(AgentBuiltins.hermesToolsets(disabled: ["vision"]), ["terminal", "file"])
        XCTAssertEqual(AgentBuiltins.hermesToolsets(disabled: ["terminal", "file", "vision"]), ["todo"])
    }

    func testCodexHasNothingToToggle() {
        XCTAssertEqual(AgentBuiltins.names(for: "codex"), [])
        XCTAssertNil(AgentBuiltins.searchWarning(agentID: "codex", disabled: ["mdfind"]))
        XCTAssertEqual(AgentBuiltins.adjustPrompt("prompt", agentID: "codex", disabled: ["mdfind"]), "prompt")
    }

    // MARK: Settings

    func testNames() {
        XCTAssertEqual(AgentBuiltins.names(for: "claude"), ["ls", "mdfind", "mdls", "head", "stat", "grep", "Read", "Glob", "Grep"])
        XCTAssertEqual(AgentBuiltins.names(for: "gemini"), ["mdfind", "mdls", "ls", "grep", "head", "stat", "read_file", "list_directory"])
        XCTAssertFalse(AgentBuiltins.names(for: "opencode").contains("external_directory"))
        XCTAssertEqual(AgentBuiltins.names(for: "hermes"), ["terminal", "file", "vision"])
    }

    func testSearchWarning() {
        XCTAssertNil(AgentBuiltins.searchWarning(agentID: "claude", disabled: ["mdfind"]))
        XCTAssertNil(AgentBuiltins.searchWarning(agentID: "claude", disabled: ["Glob"]))
        let warning = AgentBuiltins.searchWarning(agentID: "claude", disabled: ["mdfind", "Glob"])
        XCTAssertEqual(warning?.contains("mdfind or Glob"), true)
        XCTAssertNotNil(AgentBuiltins.searchWarning(agentID: "gemini", disabled: ["mdfind"]))
        XCTAssertNil(AgentBuiltins.searchWarning(agentID: "opencode", disabled: ["mdfind", "glob"]))
        XCTAssertEqual(AgentBuiltins.searchWarning(agentID: "opencode", disabled: ["mdfind", "glob", "find"])?.contains("mdfind, glob or find"), true)
        XCTAssertNotNil(AgentBuiltins.searchWarning(agentID: "hermes", disabled: ["terminal", "file"]))
    }

    // MARK: Prompt

    func testPromptUnchangedWhenNothingIsOff() {
        let prompt = SearchPromptHints.defaultTemplate
        XCTAssertEqual(AgentBuiltins.adjustPrompt(prompt, agentID: "claude", disabled: []), prompt)
        // Names another agent has (or stale ones) don't count.
        XCTAssertEqual(AgentBuiltins.adjustPrompt(prompt, agentID: "claude", disabled: ["read_file", "terminal"]), prompt)
    }

    func testDefaultTemplateHasTheHints() {
        for hint in SearchPromptHints.all {
            XCTAssertTrue(SearchPromptHints.defaultTemplate.contains(hint.text), hint.text)
        }
    }

    func testPromptDropsMdfindHintsAndNamesUnavailableTools() {
        let prompt = AgentBuiltins.adjustPrompt(SearchPromptHints.defaultTemplate, agentID: "claude", disabled: ["mdfind", "Glob"])
        XCTAssertFalse(prompt.contains("mdfind -onlyin"), prompt)
        XCTAssertFalse(prompt.contains("More Spotlight"))
        XCTAssertTrue(prompt.contains("2. Run several searches together, on names and on contents. Recent files: `ls -lt"))
        XCTAssertTrue(prompt.contains("\nWhere to look: {{searchFolders}}"))
        XCTAssertTrue(prompt.hasSuffix("\n\nUnavailable tools (turned off in Likely's settings): `mdfind`, `Glob`. Don't try them; use your other tools."), prompt)
    }

    func testPromptDropsPipedHintsWhenGrepOrHeadIsOff() {
        let noGrep = AgentBuiltins.adjustPrompt(SearchPromptHints.defaultTemplate, agentID: "claude", disabled: ["grep"])
        XCTAssertFalse(noGrep.contains("| grep -v"))
        let noHead = AgentBuiltins.adjustPrompt(SearchPromptHints.defaultTemplate, agentID: "claude", disabled: ["head"])
        XCTAssertFalse(noHead.contains("| head"))
        XCTAssertFalse(noHead.contains("pipes to `head` are fine"))
    }

    func testPromptDropsRecentFilesHint() {
        let prompt = AgentBuiltins.adjustPrompt(SearchPromptHints.defaultTemplate, agentID: "gemini", disabled: ["ls"])
        XCTAssertFalse(prompt.contains("ls -lt"))
        XCTAssertTrue(prompt.contains("mdfind -onlyin"))
        XCTAssertTrue(prompt.contains("or plain `mdfind \"term\"`.\n3. Merge"))
        XCTAssertTrue(prompt.hasSuffix("Unavailable tools (turned off in Likely's settings): `ls`. Don't try them; use your other tools."))
    }

    func testCustomTemplateGetsTheNoteOnly() {
        let prompt = AgentBuiltins.adjustPrompt("Find it with mdfind.", agentID: "opencode", disabled: ["mdfind", "read"])
        XCTAssertEqual(prompt, "Find it with mdfind.\n\nUnavailable tools (turned off in Likely's settings): `mdfind`, `read`. Don't try them; use your other tools.")
    }

    func testHermesTerminalOffDropsCommandHints() {
        let prompt = AgentBuiltins.adjustPrompt(SearchPromptHints.defaultTemplate, agentID: "hermes", disabled: ["terminal"])
        XCTAssertFalse(prompt.contains("mdfind"))
        XCTAssertFalse(prompt.contains("ls -lt"))
        XCTAssertTrue(prompt.hasSuffix("`terminal`. Don't try them; use your other tools."))
    }
}
