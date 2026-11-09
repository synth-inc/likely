import Foundation

/// A command-line tool the user lets the search agent run, stored in tools.json (see docs/TOOLS.md).
public struct CustomTool: Codable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// Command prefixes the agent may run, e.g. `rclip -n`.
    public var commands: [String]
    /// Added to the agent's prompt: when and how to use the tool.
    public var instructions: String
    /// For people and coding agents: how to install or maintain the tool. Not sent to the search agent.
    public var setup: String?

    public init(id: String, name: String, enabled: Bool = true, commands: [String], instructions: String, setup: String? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.commands = commands
        self.instructions = instructions
        self.setup = setup
    }

    /// Validation problems; a tool with any is never given to the agent.
    public var problems: [String] { ToolValidator.problems(for: self) }
    /// Enabled and valid: its commands are allowlisted and its instructions are in the prompt.
    public var isActive: Bool { enabled && problems.isEmpty }

    /// Non-empty command prefixes, trimmed.
    public var cleanedCommands: [String] {
        commands.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// An id from the name: lowercase letters, digits and dashes.
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "tool" : collapsed
    }
}

/// The contents of tools.json: `{"version": 1, "tools": [ … ]}`.
public struct ToolsFile: Equatable {
    public static let currentVersion = 1

    public var tools: [CustomTool]
    /// Entries that were skipped or fixed up while decoding, for the log and the Settings tab.
    public var issues: [String]

    public init(tools: [CustomTool] = [], issues: [String] = []) {
        self.tools = tools
        self.issues = issues
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case notJSON(String)
        case wrongShape

        public var description: String {
            switch self {
            case .notJSON(let detail): return "tools.json isn't valid JSON (\(detail))"
            case .wrongShape: return "tools.json should be an object with a \"tools\" array"
            }
        }
    }

    /// Decodes leniently: a bad entry is skipped (with an issue) instead of failing the whole file.
    /// A bare array of tools is accepted too. Throws only if the file isn't JSON or has no tool list.
    public static func decode(_ data: Data) throws -> ToolsFile {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DecodeError.notJSON((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "\(error)")
        }
        let entries: [Any]
        if let object = root as? [String: Any], let list = object["tools"] as? [Any] {
            entries = list
        } else if let list = root as? [Any] {
            entries = list
        } else if let object = root as? [String: Any], object["tools"] == nil {
            entries = []   // `{}`: no tools yet
        } else {
            throw DecodeError.wrongShape
        }

        var file = ToolsFile()
        var usedIDs = Set<String>()
        for (index, entry) in entries.enumerated() {
            let label = "Tool \(index + 1)"
            guard let dict = entry as? [String: Any] else {
                file.issues.append("\(label): not an object, skipped")
                continue
            }
            let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                file.issues.append("\(label): no \"name\", skipped")
                continue
            }

            var commands: [String] = []
            switch dict["commands"] {
            case let list as [Any]:
                commands = list.compactMap { $0 as? String }
                if commands.count != list.count { file.issues.append("\(name): non-text entries in \"commands\" ignored") }
            case let single as String:
                commands = [single]
            case nil:
                file.issues.append("\(name): no \"commands\"")
            default:
                file.issues.append("\(name): \"commands\" should be a list of strings")
            }

            var enabled = true
            if let value = dict["enabled"] {
                if let flag = value as? Bool { enabled = flag } else { file.issues.append("\(name): \"enabled\" should be true or false; treated as true") }
            }

            var id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if id.isEmpty { id = CustomTool.slug(name) }
            if usedIDs.contains(id) {
                var n = 2
                while usedIDs.contains("\(id)-\(n)") { n += 1 }
                file.issues.append("\(name): duplicate id \"\(id)\", using \"\(id)-\(n)\"")
                id = "\(id)-\(n)"
            }
            usedIDs.insert(id)

            let setup = (dict["setup"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            file.tools.append(CustomTool(id: id, name: name, enabled: enabled, commands: commands,
                                         instructions: dict["instructions"] as? String ?? "", setup: setup))
        }
        return file
    }

    public func encoded() throws -> Data {
        struct Wrapper: Encodable {
            let version: Int
            let tools: [CustomTool]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Wrapper(version: Self.currentVersion, tools: tools))
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
