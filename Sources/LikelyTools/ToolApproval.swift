import CryptoKit
import Foundation

/// Tools only run once the user has approved their exact commands and instructions. Edits made in
/// Likely approve themselves; anything else that changes tools.json (a coding agent, a script, a
/// planted file) leaves the changed tools pending until the user clicks Approve in Settings → Tools.
public enum ToolApproval {
    /// What was approved for one tool: a hash of its commands and instructions, plus the commands
    /// themselves so the Tools tab can show what changed.
    public struct Record: Codable, Equatable {
        public var fingerprint: String
        public var commands: [String]

        public init(fingerprint: String, commands: [String]) {
            self.fingerprint = fingerprint
            self.commands = commands
        }
    }

    /// Approved records by tool id.
    public typealias Approvals = [String: Record]

    /// SHA-256 over the tool's (trimmed) commands and instructions. Name, id, enabled and setup notes
    /// don't change what the agent may do, so they aren't part of it.
    public static func fingerprint(of tool: CustomTool) -> String {
        let payload: [String] = tool.cleanedCommands + ["\u{0}", tool.instructions.trimmingCharacters(in: .whitespacesAndNewlines)]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func record(for tool: CustomTool) -> Record {
        Record(fingerprint: fingerprint(of: tool), commands: tool.cleanedCommands)
    }

    public static func isApproved(_ tool: CustomTool, in approvals: Approvals) -> Bool {
        approvals[tool.id]?.fingerprint == fingerprint(of: tool)
    }

    /// An enabled, valid tool whose commands or instructions haven't been approved.
    public struct Pending: Equatable, Identifiable {
        public let tool: CustomTool
        /// Commands not in the approved version (all of them for a new tool).
        public let addedCommands: [String]
        public let removedCommands: [String]
        public let instructionsChanged: Bool
        public let isNew: Bool
        public var id: String { tool.id }

        /// A short diff for the banner, e.g. `+ rclip -n`, `- cd`, `instructions changed`.
        public var summary: [String] {
            addedCommands.map { "+ \($0)" } + removedCommands.map { "- \($0)" }
                + (instructionsChanged ? [isNew ? "new instructions" : "instructions changed"] : [])
        }
    }

    public static func pending(_ tools: [CustomTool], approvals: Approvals) -> [Pending] {
        tools.filter { $0.isActive && !isApproved($0, in: approvals) }.map { tool in
            let commands = tool.cleanedCommands
            guard let old = approvals[tool.id] else {
                return Pending(tool: tool, addedCommands: commands, removedCommands: [], instructionsChanged: true, isNew: true)
            }
            let added = commands.filter { !old.commands.contains($0) }
            let removed = old.commands.filter { !commands.contains($0) }
            // Same commands but a different fingerprint: the instructions changed.
            let sameCommands = record(for: tool).commands == old.commands
            let instructionsChanged = sameCommands || fingerprint(of: CustomTool(id: "", name: "", commands: old.commands,
                                                                                 instructions: tool.instructions)) != old.fingerprint
            return Pending(tool: tool, addedCommands: added, removedCommands: removed,
                           instructionsChanged: instructionsChanged, isNew: false)
        }
    }

    /// The tools the agent may use: enabled, valid and approved.
    public static func usable(_ tools: [CustomTool], approvals: Approvals) -> [CustomTool] {
        tools.filter { $0.isActive && isApproved($0, in: approvals) }
    }
}
