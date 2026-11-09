import LikelyStorage
import Foundation
import LikelyTools

/// The user's extra agent tools. ~/Library/Application Support/Likely/tools.json is the source of
/// truth, so a coding agent can configure Likely by editing it: the file is watched, and checked again
/// before each search, so outside edits apply without a restart. A missing or unreadable file means no
/// extra tools (the built-in search commands still work). Main thread only.
final class ToolStore: ObservableObject {
    static let shared = ToolStore()

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Likely/tools.json")

    @Published private(set) var tools: [CustomTool] = []
    /// Why the file couldn't be read at all (its tools are then ignored).
    @Published private(set) var loadError: String?
    /// Entries skipped or fixed up while reading.
    @Published private(set) var issues: [String] = []
    /// What the user approved, by tool id (UserDefaults; agents can't write Likely's preferences).
    @Published private(set) var approvals: ToolApproval.Approvals = ToolStore.loadApprovals()

    /// Posted (main thread) when tools start waiting for approval; AppDelegate badges the menu bar.
    static let approvalNeeded = Notification.Name("ToolStore.approvalNeeded")
    private static let approvalsKey = "approvedTools"
    private var announcedPending: [String] = []

    private struct Signature: Equatable {
        let modified: Date?
        let size: Int?
        let inode: Int?
    }

    private var signature: Signature??
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    private init() {
        reloadIfChanged()
        startWatching()
    }

    /// Enabled, valid and approved: the tools the agent gets.
    var activeTools: [CustomTool] { ToolApproval.usable(tools, approvals: approvals) }

    /// Enabled, valid tools changed outside Likely and not yet approved.
    var pending: [ToolApproval.Pending] { ToolApproval.pending(tools, approvals: approvals) }

    /// Command prefixes of the enabled, valid tools, without duplicates.
    var activeCommands: [String] { ToolPermissions.merged([], activeTools.flatMap(\.cleanedCommands)) }

    var promptSection: String { ToolPrompts.section(for: activeTools) }

    // MARK: Approval

    private static func loadApprovals() -> ToolApproval.Approvals {
        guard let data = UserDefaults.standard.data(forKey: approvalsKey),
              let approvals = try? JSONDecoder().decode(ToolApproval.Approvals.self, from: data) else { return [:] }
        return approvals
    }

    /// `check: false` when the tools are about to be rewritten (the reload checks then).
    private func storeApprovals(_ approvals: ToolApproval.Approvals, check: Bool = true) {
        self.approvals = approvals
        UserDefaults.standard.set(try? JSONEncoder().encode(approvals), forKey: Self.approvalsKey)
        if check { checkPending() }
    }

    /// The user clicked Approve: everything pending now runs.
    func approvePending() {
        var approvals = self.approvals
        for item in pending { approvals[item.tool.id] = ToolApproval.record(for: item.tool) }
        Log.write("tools", "approved: \(pending.map(\.tool.name).joined(separator: ", "))")
        storeApprovals(approvals)
    }

    /// Logs and announces a new set of pending tools once.
    private func checkPending() {
        let keys = pending.map { "\($0.tool.id):\(ToolApproval.fingerprint(of: $0.tool))" }
        guard keys != announcedPending else { return }
        announcedPending = keys
        if !keys.isEmpty {
            Log.write("tools", "changed outside Likely, waiting for approval: \(pending.map(\.tool.name).joined(separator: ", "))")
        }
        NotificationCenter.default.post(name: Self.approvalNeeded, object: nil)
    }

    // MARK: Reading

    private func currentSignature() -> Signature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path) else { return nil }
        return Signature(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue,
                         inode: (attributes[.systemFileNumber] as? NSNumber)?.intValue)
    }

    /// Re-reads tools.json if it changed since the last read (cheap: one stat).
    func reloadIfChanged() {
        let current = currentSignature()
        if let signature, signature == current { return }
        signature = .some(current)
        guard current != nil else {
            if !tools.isEmpty || loadError != nil { Log.write("tools", "tools.json removed; no extra tools") }
            apply(ToolsFile(), error: nil)
            checkPending()
            return
        }
        do {
            let file = try ToolsFile.decode(try Data(contentsOf: Self.fileURL))
            apply(file, error: nil)
            let active = file.tools.filter(\.isActive).map(\.name)
            Log.write("tools", "loaded \(file.tools.count) tool(s), active: \(active.isEmpty ? "none" : active.joined(separator: ", "))"
                      + (file.issues.isEmpty ? "" : "; issues: \(file.issues.joined(separator: "; "))"))
            for tool in file.tools where tool.enabled && !tool.isActive {
                Log.write("tools", "\(tool.name) disabled: \(tool.problems.joined(separator: "; "))")
            }
            checkPending()
        } catch {
            let message = (error as? ToolsFile.DecodeError)?.description ?? "Couldn't read tools.json: \(error.localizedDescription)"
            Log.write("tools", "\(message); using built-in commands only")
            apply(ToolsFile(), error: message)
        }
    }

    private func apply(_ file: ToolsFile, error: String?) {
        if tools != file.tools { tools = file.tools }
        if issues != file.issues { issues = file.issues }
        if loadError != error { loadError = error }
    }

    // MARK: Writing

    /// Adds or replaces a tool. A tool that fails validation is saved disabled.
    func save(_ tool: CustomTool) {
        var tool = tool
        tool.commands = tool.commands.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !tool.problems.isEmpty { tool.enabled = false }
        // Edits made here are the user's own: approved as saved.
        var approvals = self.approvals
        approvals[tool.id] = ToolApproval.record(for: tool)
        storeApprovals(approvals, check: false)
        var list = tools
        if let index = list.firstIndex(where: { $0.id == tool.id }) { list[index] = tool } else { list.append(tool) }
        write(list)
    }

    /// Writes an empty tool list if there's no tools.json yet (for "Reveal tools.json").
    func createFileIfMissing() {
        guard !FileManager.default.fileExists(atPath: Self.fileURL.path) else { return }
        write([])
    }

    func delete(id: String) {
        var approvals = self.approvals
        approvals[id] = nil
        storeApprovals(approvals, check: false)
        write(tools.filter { $0.id != id })
    }

    /// Turning a tool on only works if it's valid.
    func setEnabled(_ enabled: Bool, id: String) {
        guard var tool = tools.first(where: { $0.id == id }), !(enabled && !tool.problems.isEmpty) else { return }
        tool.enabled = enabled
        save(tool)
    }

    /// A fresh id for a new tool named `name`.
    func newID(for name: String) -> String {
        let base = CustomTool.slug(name)
        var id = base
        var n = 2
        while tools.contains(where: { $0.id == id }) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    private func write(_ list: [CustomTool]) {
        let fm = FileManager.default
        do {
            try OwnerOnly.createDirectory(Self.fileURL.deletingLastPathComponent())
            if loadError != nil, fm.fileExists(atPath: Self.fileURL.path) {
                // Don't silently replace a file someone was editing by hand: keep the broken one beside it.
                let backup = Self.fileURL.deletingLastPathComponent().appendingPathComponent("tools.invalid.json")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: Self.fileURL, to: backup)
                Log.write("tools", "kept the unreadable tools.json as tools.invalid.json")
            }
            try OwnerOnly.write(try ToolsFile(tools: list).encoded(), to: Self.fileURL)   // 0600, atomic
        } catch {
            Log.write("tools", "couldn't write tools.json: \(error)")
        }
        reloadIfChanged()
        checkPending()
        armFileSource()
    }

    // MARK: Watching

    /// The folder is watched for the file appearing, disappearing or being replaced (editors and
    /// agents usually write a new file and rename it), the file itself for in-place writes.
    private func startWatching() {
        let directory = Self.fileURL.deletingLastPathComponent()
        try? OwnerOnly.createDirectory(directory)
        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(fd) }
            source.resume()
            directorySource = source
        }
        armFileSource()
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(Self.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    /// Writes come in bursts; read once they settle.
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadIfChanged()
            self?.armFileSource()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
