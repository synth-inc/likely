import Foundation
import XCTest
@testable import LikelyTools

final class ToolsFileTests: XCTestCase {
    func testDecodesFullEntry() throws {
        let json = """
        {"version": 1, "tools": [{"id": "rclip", "name": "Image search", "enabled": false,
          "commands": ["cd", "rclip -n"], "instructions": "Use it for images.", "setup": "brew install rclip"}]}
        """
        let file = try ToolsFile.decode(Data(json.utf8))
        XCTAssertEqual(file.issues, [])
        XCTAssertEqual(file.tools, [CustomTool(id: "rclip", name: "Image search", enabled: false, commands: ["cd", "rclip -n"],
                                               instructions: "Use it for images.", setup: "brew install rclip")])
    }

    func testSkipsBadEntriesAndKeepsGoodOnes() throws {
        let json = """
        {"tools": [
          42,
          {"commands": ["exiftool"]},
          {"name": "  "},
          {"name": "EXIF", "commands": ["exiftool -s", 7], "instructions": "x"},
          {"name": "Single", "commands": "mdutil -s", "enabled": "yes"},
          {"name": "Dup", "id": "exif", "commands": ["a"]},
          {"name": "Dup2", "id": "exif", "commands": ["b"]}
        ]}
        """
        let file = try ToolsFile.decode(Data(json.utf8))
        XCTAssertEqual(file.tools.map(\.name), ["EXIF", "Single", "Dup", "Dup2"])
        XCTAssertEqual(file.tools[0].id, "exif")
        XCTAssertEqual(file.tools[0].commands, ["exiftool -s"])
        XCTAssertEqual(file.tools[1].commands, ["mdutil -s"])
        XCTAssertTrue(file.tools[1].enabled)
        XCTAssertEqual(file.tools[2].id, "exif-2")
        XCTAssertEqual(file.tools[3].id, "exif-3")
        XCTAssertEqual(file.issues.count, 7)
        XCTAssertTrue(file.issues[0].contains("not an object"))
        XCTAssertTrue(file.issues[1].contains("no \"name\""))
    }

    func testDefaults() throws {
        let file = try ToolsFile.decode(Data(#"[{"name": "My Tool!"}]"#.utf8))
        XCTAssertEqual(file.tools.first?.id, "my-tool")
        XCTAssertEqual(file.tools.first?.enabled, true)
        XCTAssertEqual(file.tools.first?.instructions, "")
        XCTAssertEqual(file.tools.first?.commands, [])
        XCTAssertEqual(file.tools.first?.isActive, false)   // no commands
    }

    func testEmptyObjectIsNoTools() throws {
        XCTAssertEqual(try ToolsFile.decode(Data("{}".utf8)).tools, [])
    }

    func testInvalidFilesThrow() {
        XCTAssertThrowsError(try ToolsFile.decode(Data("{ not json".utf8)))
        XCTAssertThrowsError(try ToolsFile.decode(Data(#"{"tools": "nope"}"#.utf8)))
        XCTAssertThrowsError(try ToolsFile.decode(Data(#""text""#.utf8)))
    }

    func testRoundTrip() throws {
        let file = ToolsFile(tools: [ToolPrompts.example, CustomTool(id: "b", name: "B", enabled: false, commands: ["x"], instructions: "")])
        let decoded = try ToolsFile.decode(file.encoded())
        XCTAssertEqual(decoded.tools, file.tools)
        XCTAssertEqual(decoded.issues, [])
    }
}

final class ToolValidatorTests: XCTestCase {
    func testAcceptsReadOnlyPrefixes() {
        for command in ["rclip -n", "cd", "exiftool -s -s -s", "/opt/homebrew/bin/rclip -n", "mdutil -s", "  ls  "] {
            XCTAssertNil(ToolValidator.problem(with: command), command)
        }
    }

    func testRejectsEmpty() {
        XCTAssertNotNil(ToolValidator.problem(with: ""))
        XCTAssertNotNil(ToolValidator.problem(with: "   "))
    }

    func testRejectsMetacharacters() {
        for command in ["ls; rm -rf ~", "ls | sh", "ls && rm", "ls > out", "cat < in", "echo $HOME", "echo `id`",
                        "ls\nrm", "ls\r", "ls $(id)", "ls *", "say \"hi\"", "ls 'x'", "ls \\x"] {
            XCTAssertNotNil(ToolValidator.problem(with: command), command)
        }
    }

    func testRejectsDestructiveFirstWords() {
        for command in ["rm", "rm -rf", "mv a b", "cp", "dd if=x", "sudo ls", "chmod 777", "chown me", "curl example.com",
                        "wget x", "sh -c", "bash", "zsh", "python", "python3.12 -c", "osascript -e", "open .", "kill 1",
                        "/bin/rm", "RM", "/usr/bin/sudo ls"] {
            XCTAssertNotNil(ToolValidator.problem(with: command), command)
        }
        // Only the first word counts.
        XCTAssertNil(ToolValidator.problem(with: "grep rm"))
        XCTAssertNil(ToolValidator.problem(with: "openssl-free-tool"))
    }

    func testToolProblemsAndActive() {
        var tool = CustomTool(id: "t", name: "T", commands: ["rclip -n"], instructions: "")
        XCTAssertEqual(tool.problems, [])
        XCTAssertTrue(tool.isActive)
        tool.enabled = false
        XCTAssertFalse(tool.isActive)
        tool.enabled = true
        tool.commands = ["rclip -n", "rm -rf"]
        XCTAssertEqual(tool.problems.count, 1)
        XCTAssertFalse(tool.isActive)
        tool.commands = []
        XCTAssertEqual(tool.problems, ["The tool has no commands"])
        tool.commands = ["ok"]
        tool.name = " "
        XCTAssertEqual(tool.problems, ["The tool has no name"])
    }
}

final class ToolPermissionsTests: XCTestCase {
    func testClaude() {
        XCTAssertEqual(ToolPermissions.claude(["cd", "rclip -n"]), ["Bash(cd:*)", "Bash(rclip -n:*)"])
    }

    func testGemini() {
        XCTAssertEqual(ToolPermissions.gemini(["cd", "rclip -n"]), ["run_shell_command(cd)", "run_shell_command(rclip -n)"])
    }

    func testOpenCode() {
        let rules = ToolPermissions.openCode(["rclip -n"])
        XCTAssertEqual(rules.map(\.pattern), ["rclip -n", "rclip -n *"])
        XCTAssertEqual(rules.map(\.action), ["allow", "allow"])
    }

    func testMergedKeepsOrderAndDropsDuplicates() {
        XCTAssertEqual(ToolPermissions.merged(["a", "b"], ["b", "c", "c", "a", "d"]), ["a", "b", "c", "d"])
    }

    func testOrderedJSONObjectKeepsOrderAndParses() throws {
        let inner = ToolPermissions.orderedJSONObject([("*", .string("deny")), ("rclip -n *", .string("allow")), ("q\"uote", .string("x"))])
        let json = ToolPermissions.orderedJSONObject([("*", .string("deny")), ("bash", .raw(inner))])
        XCTAssertTrue(json.hasPrefix(#"{"*":"deny","bash":{"*":"deny","rclip -n *":"allow""#), json)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((parsed["bash"] as? [String: String])?["q\"uote"], "x")
    }

    func testEveryAgentHasANote() {
        for id in ["claude", "codex", "gemini", "opencode", "hermes"] { XCTAssertNotNil(ToolPermissions.agentNotes[id], id) }
    }
}

final class AgentPathTests: XCTestCase {
    func testDirectoriesOrder() {
        let dirs = AgentPath.directories(agentExecutable: "/Users/me/.local/bin/claude", inherited: "/x:/y", home: "/Users/me")
        XCTAssertEqual(dirs, ["/Users/me/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Users/me/.local/bin",
                              "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/x", "/y"])
    }

    func testResolve() {
        let exists: (String) -> Bool = { $0 == "/opt/homebrew/bin/rclip" || $0 == "/abs/tool" }
        let dirs = ["/usr/bin", "/opt/homebrew/bin"]
        XCTAssertEqual(AgentPath.resolve("rclip -n", in: dirs, isExecutable: exists), .found("/opt/homebrew/bin/rclip"))
        XCTAssertEqual(AgentPath.resolve("cd", in: dirs, isExecutable: exists), .builtin)
        XCTAssertEqual(AgentPath.resolve("/abs/tool -x", in: dirs, isExecutable: exists), .found("/abs/tool"))
        XCTAssertEqual(AgentPath.resolve("nope", in: dirs, isExecutable: exists), .notFound)
        XCTAssertEqual(AgentPath.resolve("", in: dirs, isExecutable: exists), .notFound)
    }
}

final class ToolPromptsTests: XCTestCase {
    func testSectionEmptyWithoutActiveTools() {
        XCTAssertEqual(ToolPrompts.section(for: []), "")
        let off = CustomTool(id: "a", name: "A", enabled: false, commands: ["a"], instructions: "x")
        let invalid = CustomTool(id: "b", name: "B", commands: ["rm"], instructions: "x")
        XCTAssertEqual(ToolPrompts.section(for: [off, invalid]), "")
    }

    func testSectionListsActiveTools() {
        let tools = [
            CustomTool(id: "r", name: "Images", commands: ["cd", " rclip -n "], instructions: "Describe the picture.\n\n  Run `rclip -n`."),
            CustomTool(id: "e", name: "EXIF", commands: ["exiftool -s"], instructions: ""),
            CustomTool(id: "o", name: "Off", enabled: false, commands: ["x"], instructions: "hidden"),
        ]
        XCTAssertEqual(ToolPrompts.section(for: tools), """
        Extra tools you can use (installed by the user; run them like the search commands above):
        - Images (allowed: `cd`, `rclip -n`): Describe the picture.
          Run `rclip -n`.
        - EXIF (allowed: `exiftool -s`)
        """)
    }

    func testExampleIsValid() {
        XCTAssertEqual(ToolPrompts.example.problems, [])
    }

    func testSetupPromptHasSchemaAndRules() throws {
        let prompt = ToolPrompts.setupPrompt
        XCTAssertTrue(prompt.contains("~/Library/Application Support/Likely/tools.json"))
        for field in ["\"id\"", "\"name\"", "\"enabled\"", "\"commands\"", "\"instructions\"", "\"setup\"", "\"version\""] {
            XCTAssertTrue(prompt.contains(field), field)
        }
        XCTAssertTrue(prompt.contains(ToolPrompts.exampleJSON))
        XCTAssertTrue(prompt.contains(ToolValidator.forbiddenCharactersDescription))
        for word in ToolValidator.blockedFirstWords { XCTAssertTrue(prompt.contains(word), word) }
        XCTAssertTrue(prompt.contains("/opt/homebrew/bin"))
        XCTAssertTrue(prompt.hasSuffix("What I want: "))

        // The embedded example is a valid tools.json.
        let file = try ToolsFile.decode(Data(ToolPrompts.exampleJSON.utf8))
        XCTAssertEqual(file.tools, [ToolPrompts.example])
    }
}
