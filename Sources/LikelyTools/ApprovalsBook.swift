import Foundation
import LikelyStorage

/// The saved tool approvals as the app holds them (sealed: see ProtectedSettings). A save rewrites the
/// whole set, so it only goes through when the stored set was read: while it can't be read or verified
/// (the Keychain didn't answer, or it changed outside Likely and waits for the user in Settings), saving
/// would replace it with a smaller one. So every change reads the stored set again first, and is
/// refused, changing nothing, while that read fails. Meanwhile no tool counts as approved.
public struct ApprovalsBook {
    public private(set) var approvals: ToolApproval.Approvals = [:]
    /// The stored approvals couldn't be read or verified.
    public private(set) var unreadable = false

    private let read: () -> SettingsSeal.Read<Data>
    private let write: (Data) -> Bool

    /// `write` returns false if the approvals couldn't be saved.
    public init(read: @escaping () -> SettingsSeal.Read<Data>, write: @escaping (Data) -> Bool) {
        self.read = read
        self.write = write
        reload()
    }

    public mutating func reload() {
        switch read() {
        case .absent:
            approvals = [:]
            unreadable = false
        case .valid(let data):
            // A verified value that doesn't decode can't be anyone's approvals: start over.
            approvals = (try? JSONDecoder().decode(ToolApproval.Approvals.self, from: data)) ?? [:]
            unreadable = false
        case .tampered, .unsealed, .unverifiable:
            approvals = [:]
            unreadable = true
        }
    }

    /// Applies `change` to the stored approvals (read again first) and saves them. Returns false,
    /// saving nothing, while they can't be read, or if saving failed.
    @discardableResult
    public mutating func update(_ change: (inout ToolApproval.Approvals) -> Void) -> Bool {
        reload()
        guard !unreadable else { return false }
        var changed = approvals
        change(&changed)
        guard let data = try? JSONEncoder().encode(changed), write(data) else { return false }
        approvals = changed
        return true
    }
}
