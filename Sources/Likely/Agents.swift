import Foundation

/// Coding agents Likely can (or will) drive. Claude Code and Codex have runners today; the rest are
/// detected and listed so onboarding/settings can show them, and get runners (likely via ACP) later.
struct AgentKind: Identifiable, Hashable {
    let id: String
    let name: String
    let maker: String
    let executables: [String]
    let isSupported: Bool
    let installCommand: String
    let homepage: URL

    static let all: [AgentKind] = [
        AgentKind(id: "claude", name: "Claude Code", maker: "Anthropic", executables: ["claude"], isSupported: true,
                  installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
                  homepage: URL(string: "https://claude.com/claude-code")!),
        AgentKind(id: "codex", name: "Codex", maker: "OpenAI", executables: ["codex"], isSupported: true,
                  installCommand: "npm install -g @openai/codex",
                  homepage: URL(string: "https://github.com/openai/codex")!),
        AgentKind(id: "gemini", name: "Gemini CLI", maker: "Google", executables: ["gemini"], isSupported: true,
                  installCommand: "npm install -g @google/gemini-cli",
                  homepage: URL(string: "https://github.com/google-gemini/gemini-cli")!),
        AgentKind(id: "opencode", name: "OpenCode", maker: "open source", executables: ["opencode"], isSupported: true,
                  installCommand: "brew install anomalyco/tap/opencode",
                  homepage: URL(string: "https://opencode.ai")!),
        AgentKind(id: "hermes", name: "Hermes Agent", maker: "Nous Research", executables: ["hermes"], isSupported: true,
                  installCommand: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash",
                  homepage: URL(string: "https://github.com/NousResearch/hermes-agent")!),
        AgentKind(id: "goose", name: "Goose", maker: "Block", executables: ["goose"], isSupported: false,
                  installCommand: "brew install block-goose-cli",
                  homepage: URL(string: "https://github.com/block/goose")!),
        AgentKind(id: "pi", name: "Pi", maker: "open source", executables: ["pi"], isSupported: false,
                  installCommand: "curl -fsSL https://pi.dev/install.sh | sh",
                  homepage: URL(string: "https://github.com/badlogic/pi-mono")!),
    ]

    static func with(id: String) -> AgentKind? { all.first { $0.id == id } }
}

/// Finds which agents are installed. GUI apps don't get the shell's PATH (nvm, Homebrew, …), so check
/// common locations and then ask an interactive login shell, once for all agents.
final class AgentDetector: ObservableObject {
    static let shared = AgentDetector()

    @Published private(set) var paths: [String: String] = [:]
    @Published private(set) var isScanning = false

    func path(for agent: AgentKind) -> String? { paths[agent.id] }

    var installed: [AgentKind] { AgentKind.all.filter { paths[$0.id] != nil } }

    func scan(completion: (() -> Void)? = nil) {
        guard !isScanning else { return }
        isScanning = true
        // Debug: `defaults write inc.synth.likely simulateNoAgents -bool true` to preview the
        // experience for someone without a coding agent.
        let simulateNone = UserDefaults.standard.bool(forKey: "simulateNoAgents")
        DispatchQueue.global(qos: .userInitiated).async {
            let found = simulateNone ? [:] : Self.locateAll()
            DispatchQueue.main.async {
                self.paths = found
                self.isScanning = false
                Log.write("agents", "found: \(found.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
                completion?()
            }
        }
    }

    private static func locateAll() -> [String: String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        var found: [String: String] = [:]
        for agent in AgentKind.all {
            for exe in agent.executables {
                if let hit = dirs.map({ "\($0)/\(exe)" }).first(where: fm.isExecutableFile(atPath:)) {
                    found[agent.id] = hit
                    break
                }
            }
        }

        let missing = AgentKind.all.filter { found[$0.id] == nil }.flatMap { agent in agent.executables.map { (agent.id, $0) } }
        guard !missing.isEmpty else { return found }
        // One shell for everything; prints "id<TAB>path" per hit.
        let script = missing.map { "p=$(command -v \($0.1) 2>/dev/null) && printf '%s\\t%s\\n' \($0.0) \"$p\"" }.joined(separator: "; ")
        // Runs on a background queue (see `scan`), with a timeout for slow or broken shell setups.
        guard let output = LoginShell.run(script) else { return found }
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix("/"), fm.isExecutableFile(atPath: parts[1]), found[parts[0]] == nil else { continue }
            found[parts[0]] = parts[1]
        }
        return found
    }
}
