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
    /// What the user approved, by tool id (UserDefaults, sealed: see ProtectedSettings).
    @Published private(set) var approvals: ToolApproval.Approvals = [:]
    /// Set when approvals couldn't be saved because the saved ones can't be verified (see ApprovalsBook).
    @Published private(set) var approvalsProblem: String?
    private var book = ApprovalsBook(read: { ProtectedSettings.dataRead(ToolStore.approvalsKey) },
                                     write: { ProtectedSettings.set($0, forKey: ToolStore.approvalsKey) })

    /// Posted (main thread) when tools start waiting for approval; AppDelegate badges the menu bar.
    static let approvalNeeded = Notification.Name("ToolStore.approvalNeeded")
    /// Sealed (ProtectedSettings): approvals written outside Likely are ignored, so those tools wait for Approve.
    static let approvalsKey = ProtectedSettings.approvedTools
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
        approvals = book.approvals
        reloadIfChanged()
        startWatching()
        // Kept or reset in Settings, or verified after the Keychain answered again.
        NotificationCenter.default.addObserver(forName: ProtectedSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadApprovals()
        }
    }

    /// Enabled, valid, approved, and every private data area it needs turned on (Settings →
    /// Permissions): the tools the agent gets. A tool whose areas are still off isn't used, since its
    /// commands would fail in the sandbox (and the user hasn't agreed to open them).
    var activeTools: [CustomTool] {
        PrivateDataAccess.activeTools(tools, approvals: approvals) { PrivateDataAccess.isAllowed($0) }
    }

    /// Whether `tool` changed outside Likely and waits for the user's Approve.
    func isPending(_ tool: CustomTool) -> Bool { pending.contains { $0.tool.id == tool.id } }

    /// Areas `tool` needs that are still off.
    func unmetNeeds(of tool: CustomTool) -> [PrivateDataArea] { PrivateDataAccess.unmetNeeds(of: tool) }

    /// A Private data toggle changed: views showing tools redraw.
    func privateDataChanged() { objectWillChange.send() }

    /// Enabled, valid tools changed outside Likely and not yet approved.
    var pending: [ToolApproval.Pending] { ToolApproval.pending(tools, approvals: approvals) }

    /// Command prefixes of the enabled, valid tools, without duplicates.
    var activeCommands: [String] { Self.commands(of: activeTools) }

    var promptSection: String { ToolPrompts.section(for: activeTools) }

    /// Command prefixes of `tools`, without duplicates.
    static func commands(of tools: [CustomTool]) -> [String] { ToolPermissions.merged([], tools.flatMap(\.cleanedCommands)) }

    // MARK: Approval

    private func reloadApprovals() {
        book.reload()
        if approvals != book.approvals { approvals = book.approvals }
        if !book.unreadable { approvalsProblem = nil }
        checkPending()
    }

    /// Changes the saved approvals (read again first). Refused while they can't be verified, so a
    /// Keychain hiccup or an unconfirmed outside change never shrinks them. `check: false` when the
    /// tools are about to be rewritten (the reload checks then).
    @discardableResult
    private func updateApprovals(check: Bool = true, _ change: (inout ToolApproval.Approvals) -> Void) -> Bool {
        let saved = book.update(change)
        approvals = book.approvals
        if saved {
            approvalsProblem = nil
        } else {
            approvalsProblem = book.unreadable
                ? "Likely couldn't verify your saved tool approvals, so it can't change them now. Check the notice at the top of Settings, then try again."
                : "Likely couldn't save your tool approvals. Try again."
            Log.write("tools", "approvals not saved (\(public: book.unreadable ? "saved ones unverified" : "save failed"))")
        }
        if check { checkPending() }
        return saved
    }

    /// The user clicked Approve: everything pending now runs.
    func approvePending() {
        let approving = pending
        guard updateApprovals({ approvals in
            for item in ToolApproval.pending(tools, approvals: approvals) { approvals[item.tool.id] = ToolApproval.record(for: item.tool) }
        }) else { return }
        Log.write("tools", "approved \(approving.count): \(sensitive: approving.map(\.tool.name))")
    }

    /// Logs and announces a new set of pending tools once.
    private func checkPending() {
        let keys = pending.map { "\($0.tool.id):\(ToolApproval.fingerprint(of: $0.tool))" }
        guard keys != announcedPending else { return }
        announcedPending = keys
        if !keys.isEmpty {
            Log.write("tools", "changed outside Likely, waiting for approval: \(sensitive: pending.map(\.tool.name))")
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
            Log.write("tools", "loaded \(file.tools.count) tool(s), \(active.count) active: \(sensitive: active); \(file.issues.count) issue(s) \(sensitive: file.issues)")
            for tool in file.tools where tool.enabled && !tool.isActive {
                Log.write("tools", "\(sensitive: tool.name) disabled: \(tool.problems.count) problem(s) \(sensitive: tool.problems)")
            }
            checkPending()
        } catch {
            let message = (error as? ToolsFile.DecodeError)?.description ?? "Couldn't read tools.json: \(error.localizedDescription)"
            Log.write("tools", "\(error: error); using built-in commands only")
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
        let approved = tool
        updateApprovals(check: false) { $0[approved.id] = ToolApproval.record(for: approved) }
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
        updateApprovals(check: false) { $0[id] = nil }
        write(tools.filter { $0.id != id })
    }

    /// Turning a tool on only works if it's valid. Unlike `save` (an edit made in Likely's editor),
    /// this never approves anything (ToolApproval.afterToggle): a tool changed outside Likely stays
    /// pending until the user clicks Approve, whatever its switch says.
    func setEnabled(_ enabled: Bool, id: String) {
        guard var tool = tools.first(where: { $0.id == id }), !(enabled && !tool.problems.isEmpty) else { return }
        tool.enabled = enabled
        let toggled = tool
        updateApprovals(check: false) { $0 = ToolApproval.afterToggle(toggled, approvals: $0) }
        write(tools.map { $0.id == id ? tool : $0 })
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
            Log.write("tools", "couldn't write tools.json: \(error: error)")
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

extension AgentLaunchOptions {
    /// The command prefixes this launch allowlists: its own tool set, or else the app's.
    var toolCommands: [String] { tools.map(ToolStore.commands(of:)) ?? ToolStore.shared.activeCommands }
}
