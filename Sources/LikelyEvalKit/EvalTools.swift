import CryptoKit
import Foundation

/// Which eval cases get the user's own tools (tools.json, see docs/TOOLS.md). See docs/EVALS.md.
public enum EvalToolPolicy {
    /// - Personal cases use the user's enabled, approved tools, exactly as the app does, so adding a
    ///   tool and running the evals again measures the tool.
    /// - Fixture cases (`source: "fixture"`, or anything in the public fixtures suite) ignore them,
    ///   so results stay comparable across machines. `--with-tools` (`withTools`) opts them in.
    /// - A case's `context.useTools` decides for that case, either way.
    public static func usesTools(_ evalCase: EvalCase, inFixtureSuite: Bool, withTools: Bool) -> Bool {
        if let explicit = evalCase.context?.useTools { return explicit }
        if withTools { return true }
        return !(inFixtureSuite || evalCase.source == "fixture")
    }
}

/// The user's tools a run gave the agent, recorded in results.json so runs with different tools
/// are told apart: ids, plus a hash of each tool's commands and instructions (what the agent sees).
public struct EvalToolSet: Codable, Equatable {
    public struct Tool: Codable, Equatable {
        public var id: String
        /// SHA-256 prefix of the tool's commands and instructions.
        public var hash: String
        public init(id: String, hash: String) {
            self.id = id
            self.hash = hash
        }
    }

    /// Sorted by id.
    public var tools: [Tool]
    /// SHA-256 prefix over every tool's id and hash; empty when there are no tools.
    public var hash: String

    public var ids: [String] { tools.map(\.id) }
    public var isEmpty: Bool { tools.isEmpty }

    public static let empty = EvalToolSet(tools: [])

    public init(tools: [Tool]) {
        self.tools = tools.sorted { $0.id < $1.id }
        hash = self.tools.isEmpty ? "" : Self.digest(self.tools.map { "\($0.id)=\($0.hash)" }.joined(separator: "\n"))
    }

    /// From the tools' ids, command prefixes and agent instructions.
    public init(_ tools: [(id: String, commands: [String], instructions: String)]) {
        self.init(tools: tools.map { tool in
            Tool(id: tool.id, hash: Self.digest(tool.commands.joined(separator: "\n") + "\u{0}" + tool.instructions))
        })
    }

    /// What changed since `previous`: "+id" added, "-id" removed, "~id" edited (commands or
    /// instructions). Empty when the sets are the same.
    public func changes(since previous: EvalToolSet) -> [String] {
        let old = Dictionary(previous.tools.map { ($0.id, $0.hash) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(tools.map { ($0.id, $0.hash) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for tool in tools {
            if let before = old[tool.id] {
                if before != tool.hash { out.append("~" + tool.id) }
            } else {
                out.append("+" + tool.id)
            }
        }
        for tool in previous.tools where new[tool.id] == nil { out.append("-" + tool.id) }
        return out
    }

    /// "rclip, notes (a1b2c3d4)" or "none".
    public var summary: String { isEmpty ? "none" : ids.joined(separator: ", ") + " (\(hash))" }

    static func digest(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}
