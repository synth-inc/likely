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
        /// The private data areas approved with it (nil in records from before `needs`).
        public var needs: [String]?

        public init(fingerprint: String, commands: [String], needs: [String]? = nil) {
            self.fingerprint = fingerprint
            self.commands = commands
            self.needs = needs
        }
    }

    /// Approved records by tool id.
    public typealias Approvals = [String: Record]

    /// SHA-256 over the tool's (trimmed) commands, instructions and `needs`. Name, id, enabled and
    /// setup notes don't change what the agent may do, so they aren't part of it. `needs` is, so a tool
    /// planted or edited outside Likely can't quietly ask for Mail: it waits for approval like a new
    /// command. (Only added when there are needs, so approvals made before `needs` existed still hold.)
    public static func fingerprint(of tool: CustomTool) -> String {
        var payload: [String] = tool.cleanedCommands + ["\u{0}", tool.instructions.trimmingCharacters(in: .whitespacesAndNewlines)]
        // Unknown ids too (raw, trimmed): they make the tool invalid anyway, but must not be invisible.
        let needs = (tool.normalizedNeeds + PrivateDataAccess.unknownNeeds(tool.needs).map { $0.trimmingCharacters(in: .whitespaces) }).sorted()
        if !needs.isEmpty { payload += ["\u{0}needs"] + needs }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func record(for tool: CustomTool) -> Record {
        Record(fingerprint: fingerprint(of: tool), commands: tool.cleanedCommands,
               needs: tool.normalizedNeeds.isEmpty ? nil : tool.normalizedNeeds)
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
        /// Private data areas not in the approved version.
        public let addedNeeds: [String]
        public let removedNeeds: [String]
        public let isNew: Bool
        public var id: String { tool.id }

        /// A short diff for the banner, e.g. `+ rclip -n`, `- cd`, `instructions changed`.
        public var summary: [String] {
            addedCommands.map { "+ \($0)" } + removedCommands.map { "- \($0)" }
                + addedNeeds.map { "+ needs access to \(ToolApproval.phrase(need: $0))" }
                + removedNeeds.map { "- needs access to \(ToolApproval.phrase(need: $0))" }
                + (instructionsChanged ? [isNew ? "new instructions" : "instructions changed"] : [])
        }
    }

    public static func pending(_ tools: [CustomTool], approvals: Approvals) -> [Pending] {
        tools.filter { $0.isActive && !isApproved($0, in: approvals) }.map { tool in
            let commands = tool.cleanedCommands
            let needs = tool.normalizedNeeds
            guard let old = approvals[tool.id] else {
                return Pending(tool: tool, addedCommands: commands, removedCommands: [], instructionsChanged: true,
                               addedNeeds: needs, removedNeeds: [], isNew: true)
            }
            let added = commands.filter { !old.commands.contains($0) }
            let removed = old.commands.filter { !commands.contains($0) }
            let oldNeeds = old.needs ?? []
            let addedNeeds = needs.filter { !oldNeeds.contains($0) }
            let removedNeeds = oldNeeds.filter { !needs.contains($0) }
            // Rebuild the approved version with today's instructions: if that matches, they didn't change.
            let withOldCommands = CustomTool(id: "", name: "", commands: old.commands, instructions: tool.instructions, needs: oldNeeds)
            let instructionsChanged = fingerprint(of: withOldCommands) != old.fingerprint
            return Pending(tool: tool, addedCommands: added, removedCommands: removed,
                           instructionsChanged: instructionsChanged, addedNeeds: addedNeeds, removedNeeds: removedNeeds, isNew: false)
        }
    }

    /// "your Photos", or the raw id for an unknown one.
    static func phrase(need: String) -> String { PrivateDataArea(id: need)?.phrase ?? need }

    /// Approvals after the user flips a tool's switch (Settings → Tools, or Allow on its needs). Being
    /// enabled isn't part of what's approved, so the switch never approves anything: a record that
    /// already matches the tool is refreshed (e.g. one made before `needs` existed), any other is left
    /// as it is, so a tool changed outside Likely stays pending until the user clicks Approve.
    public static func afterToggle(_ tool: CustomTool, approvals: Approvals) -> Approvals {
        guard isApproved(tool, in: approvals) else { return approvals }
        var updated = approvals
        updated[tool.id] = record(for: tool)
        return updated
    }

    /// The tools the agent may use: enabled, valid and approved.
    public static func usable(_ tools: [CustomTool], approvals: Approvals) -> [CustomTool] {
        tools.filter { $0.isActive && isApproved($0, in: approvals) }
    }
}
