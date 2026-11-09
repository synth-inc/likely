import CryptoKit
import LocalAuthentication
import Foundation
import XCTest
@testable import LikelyStorage

/// A fresh temporary folder per test (never the real ~/Library/Application Support/Likely).
class TempDirTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("likely-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func mode(_ url: URL) -> mode_t? { OwnerOnly.mode(url.path) }
}

final class OwnerOnlyTests: TempDirTestCase {
    func testCreateDirectoryMakesEveryNewLevel0700() throws {
        let nested = dir.appendingPathComponent("a/b/c")
        try OwnerOnly.createDirectory(nested)
        for path in ["a", "a/b", "a/b/c"] { XCTAssertEqual(mode(dir.appendingPathComponent(path)), 0o700, path) }
        try OwnerOnly.createDirectory(nested)   // existing: fine
    }

    func testCreateDirectoryRefusesAFile() throws {
        let file = dir.appendingPathComponent("f")
        try OwnerOnly.write(Data("x".utf8), to: file)
        XCTAssertThrowsError(try OwnerOnly.createDirectory(file.appendingPathComponent("sub")))
    }

    func testWriteIsAtomicAndOwnerOnly() throws {
        let url = dir.appendingPathComponent("new/file.json")
        try OwnerOnly.write(Data("one".utf8), to: url)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(mode(url.deletingLastPathComponent()), 0o700)
        // Replacing a 0644 file leaves a 0600 one, and no temporary files behind.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try OwnerOnly.write("two", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two")
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["file.json"])
    }

    func testWriteNeverPassesThrough0644EvenWithPermissiveUmask() throws {
        let old = umask(0)
        defer { umask(old) }
        let url = dir.appendingPathComponent("u/file")
        try OwnerOnly.write(Data("x".utf8), to: url)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(mode(url.deletingLastPathComponent()), 0o700)
    }

    func testExecutableMode() throws {
        let url = dir.appendingPathComponent("bin/stub")
        try OwnerOnly.write(Data("#!/bin/sh\n".utf8), to: url, mode: OwnerOnly.executableMode)
        XCTAssertEqual(mode(url), 0o700)
    }

    func testOpenForWritingAppendsAndTruncates() throws {
        let url = dir.appendingPathComponent("logs/likely.log")
        var handle = try OwnerOnly.openForWriting(url, truncate: false)
        handle.write(Data("a\n".utf8))
        try handle.close()
        handle = try OwnerOnly.openForWriting(url, truncate: false)
        handle.write(Data("b\n".utf8))
        try handle.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\n")
        XCTAssertEqual(mode(url), 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        handle = try OwnerOnly.openForWriting(url, truncate: true)
        handle.write(Data("c".utf8))
        try handle.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "c")
        XCTAssertEqual(mode(url), 0o600, "an existing wider file is narrowed")
    }

    func testCreateExclusiveNeverTruncates() throws {
        let url = dir.appendingPathComponent("cases.jsonl")
        XCTAssertTrue(try OwnerOnly.createExclusive(url))
        XCTAssertEqual(mode(url), 0o600)
        try Data("keep".utf8).write(to: url)
        XCTAssertFalse(try OwnerOnly.createExclusive(url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
    }

    func testRepairNarrowsEverythingButFollowsNoLinks() throws {
        let fm = FileManager.default
        let root = dir.appendingPathComponent("Likely")
        let outside = dir.appendingPathComponent("outside.txt")
        try fm.createDirectory(at: root.appendingPathComponent("evals/screenshots"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: root.appendingPathComponent("tools.json").path, contents: Data(), attributes: [.posixPermissions: 0o644])
        fm.createFile(atPath: root.appendingPathComponent("evals/screenshots/a.png").path, contents: Data(), attributes: [.posixPermissions: 0o666])
        fm.createFile(atPath: root.appendingPathComponent("stub").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: outside.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        XCTAssertGreaterThan(OwnerOnly.repair(root), 0)
        XCTAssertEqual(mode(root), 0o700)
        XCTAssertEqual(mode(root.appendingPathComponent("evals")), 0o700)
        XCTAssertEqual(mode(root.appendingPathComponent("evals/screenshots")), 0o700)
        XCTAssertEqual(mode(root.appendingPathComponent("tools.json")), 0o600)
        XCTAssertEqual(mode(root.appendingPathComponent("evals/screenshots/a.png")), 0o600)
        XCTAssertEqual(mode(root.appendingPathComponent("stub")), 0o700)
        XCTAssertEqual(mode(outside), 0o644, "a link's target outside the folder is left alone")
        XCTAssertEqual(OwnerOnly.repair(root), 0, "nothing left to fix")
    }

    func testRepairFollowsALinkedRoot() throws {
        let real = dir.appendingPathComponent("Likely.noindex")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("Likely").path, withDestinationPath: "Likely.noindex")
        OwnerOnly.repair(dir.appendingPathComponent("Likely"))
        XCTAssertEqual(mode(real), 0o700)
    }

    /// A `Likely` link anywhere but `Likely.noindex` next to it (planted, or the user's own) isn't
    /// followed: nothing outside Likely's folders is chmodded.
    func testRepairDoesntFollowALinkedRootElsewhere() throws {
        let fm = FileManager.default
        let elsewhere = dir.appendingPathComponent("Documents")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: elsewhere.appendingPathComponent("notes.txt").path, contents: Data(), attributes: [.posixPermissions: 0o644])
        let support = dir.appendingPathComponent("Support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: support.appendingPathComponent("Likely").path, withDestinationPath: elsewhere.path)
        XCTAssertEqual(OwnerOnly.repair(support.appendingPathComponent("Likely")), 0)
        XCTAssertEqual(mode(elsewhere), 0o755)
        XCTAssertEqual(mode(elsewhere.appendingPathComponent("notes.txt")), 0o644)

        // Named like the target but in another folder, or a link onward from the right name: also not followed.
        let other = dir.appendingPathComponent("Other/Likely.noindex")
        try fm.createDirectory(at: other, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("Likely").path, withDestinationPath: other.path)
        XCTAssertEqual(OwnerOnly.repair(dir.appendingPathComponent("Likely")), 0)
        XCTAssertEqual(mode(other), 0o755)
        try fm.createSymbolicLink(atPath: support.appendingPathComponent("Logs.noindex").path, withDestinationPath: elsewhere.path)
        try fm.createSymbolicLink(atPath: support.appendingPathComponent("Logs").path, withDestinationPath: "Logs.noindex")
        XCTAssertEqual(OwnerOnly.repair(support.appendingPathComponent("Logs")), 0)
        XCTAssertEqual(mode(elsewhere), 0o755)
    }
}

final class DataCipherTests: XCTestCase {
    func testLineRoundTrip() throws {
        let store = InMemoryKeyStore()
        let cipher = DataCipher(store: store)
        let text = #"{"id":"a","queries":["my lease x"]}"#
        let line = try cipher.sealLine(text)
        XCTAssertTrue(line.hasPrefix("lk1:"))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("lease"))
        XCTAssertEqual(try cipher.openLine(line), text)
        XCTAssertEqual(store.key?.count, 32, "a 256-bit key was made on first use")
        // Each seal uses a fresh nonce.
        XCTAssertNotEqual(try cipher.sealLine(text), line)
        // A new cipher with the same stored key reads it.
        XCTAssertEqual(try DataCipher(store: store).openLine(line), text)
    }

    func testFileRoundTrip() throws {
        let cipher = DataCipher(store: InMemoryKeyStore())
        let png = Data([0x89, 0x50, 0x4E, 0x47] + (0..<5000).map { UInt8($0 % 251) })
        let sealed = try cipher.sealFile(png)
        XCTAssertTrue(DataCipher.isSealedFile(sealed))
        XCTAssertNil(sealed.range(of: png.prefix(64)))
        XCTAssertEqual(try cipher.openFile(sealed), png)
    }

    func testOtherKeyIsReportedAsSuch() throws {
        let line = try DataCipher(store: InMemoryKeyStore()).sealLine("secret")
        let file = try DataCipher(store: InMemoryKeyStore()).sealFile(Data("png".utf8))
        let other = DataCipher(store: InMemoryKeyStore(key: Data(repeating: 7, count: 32)))
        XCTAssertThrowsError(try other.openLine(line)) { XCTAssertEqual($0 as? DataCipher.CipherError, .otherKey) }
        XCTAssertThrowsError(try other.openFile(file)) { XCTAssertEqual($0 as? DataCipher.CipherError, .otherKey) }
    }

    func testTamperingAndWrongPurposeAreDamaged() throws {
        let cipher = DataCipher(store: InMemoryKeyStore())
        let line = try cipher.sealLine("secret")
        var bytes = Array(line)
        let i = bytes.count - 5
        bytes[i] = bytes[i] == "A" ? "B" : "A"
        XCTAssertThrowsError(try cipher.openLine(String(bytes))) { XCTAssertEqual($0 as? DataCipher.CipherError, .damaged) }
        XCTAssertThrowsError(try cipher.openLine("lk1:zz:notbase64")) { XCTAssertEqual($0 as? DataCipher.CipherError, .damaged) }
        XCTAssertThrowsError(try cipher.openLine("plain text"))
        // A history line can't be opened as a screenshot or the other way round.
        XCTAssertThrowsError(try cipher.openLine(line, purpose: .screenshot)) { XCTAssertEqual($0 as? DataCipher.CipherError, .damaged) }
        let file = try cipher.sealFile(Data("x".utf8), purpose: .screenshot)
        XCTAssertThrowsError(try cipher.openFile(file, purpose: .historyLine))
        XCTAssertThrowsError(try cipher.openFile(Data("LKE1".utf8)))
    }

    func testReadingNeverMakesAKey() throws {
        let store = InMemoryKeyStore()
        let line = try DataCipher(store: InMemoryKeyStore()).sealLine("x")
        let cipher = DataCipher(store: store)
        XCTAssertFalse(cipher.hasKey)
        XCTAssertThrowsError(try cipher.openLine(line)) { XCTAssertEqual($0 as? DataCipher.CipherError, .otherKey) }
        XCTAssertNil(store.key)
    }

    func testUnreadableKeyIsNeverReplaced() throws {
        struct Locked: Error {}
        let store = InMemoryKeyStore(key: Data(repeating: 1, count: 32))
        store.failure = Locked()
        let cipher = DataCipher(store: store)
        XCTAssertThrowsError(try cipher.sealLine("x")) {
            guard case .keyUnavailable = $0 as? DataCipher.CipherError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(store.key, Data(repeating: 1, count: 32), "the existing key wasn't overwritten")
        // Once the store can be read again, the same key is used.
        store.failure = nil
        let line = try cipher.sealLine("x")
        XCTAssertEqual(try DataCipher(store: InMemoryKeyStore(key: Data(repeating: 1, count: 32))).openLine(line), "x")
    }

    /// Two processes make the key at once: the one whose add fails with a duplicate uses the other's.
    func testDuplicateKeyOnCreateUsesTheStoredOne() throws {
        final class RacingStore: DataKeyStore {
            let winner = Data(repeating: 7, count: 32)
            var stored: Data?
            func loadKey() throws -> Data? { stored }
            func storeKey(_ key: Data) throws {
                stored = winner   // someone else got there first
                throw DataKeyAlreadyStored()
            }
        }
        let store = RacingStore()
        let cipher = DataCipher(store: store)
        let line = try cipher.sealLine("x")
        XCTAssertEqual(try DataCipher(store: InMemoryKeyStore(key: store.winner)).openLine(line), "x", "sealed with the winner's key")
        XCTAssertEqual(try cipher.openLine(line), "x")
    }

    func testWrongSizeKeyIsRefused() {
        let cipher = DataCipher(store: InMemoryKeyStore(key: Data(repeating: 1, count: 16)))
        XCTAssertThrowsError(try cipher.sealLine("x"))
    }
}

final class SpotlightExclusionTests: TempDirTestCase {
    func testMovesAFolderAndLinksIt() throws {
        let folder = dir.appendingPathComponent("Likely")
        try OwnerOnly.write("{}", to: folder.appendingPathComponent("tools.json"))
        XCTAssertEqual(try SpotlightExclusion.exclude(folder), .excluded)
        let real = dir.appendingPathComponent("Likely.noindex")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.path), "Likely.noindex")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("tools.json"), encoding: .utf8), "{}")
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("tools.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent(".metadata_never_index").path))
        XCTAssertEqual(try SpotlightExclusion.exclude(folder), .alreadyExcluded)
    }

    func testCreatesItWhenMissing() throws {
        let folder = dir.appendingPathComponent("Logs/Likely")
        XCTAssertEqual(try SpotlightExclusion.exclude(folder), .excluded)
        XCTAssertEqual(OwnerOnly.mode(dir.appendingPathComponent("Logs/Likely.noindex").path), 0o700)
        try OwnerOnly.createDirectory(folder.appendingPathComponent("sub"))   // through the link
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Logs/Likely.noindex/sub").path))
    }

    /// An earlier launch was split (a log line recreated Logs/Likely before the link was made): both are
    /// real folders. Everything ends up in the .noindex one, nothing is overwritten, and the link is made.
    func testMergesASplitFolder() throws {
        let fm = FileManager.default
        let folder = dir.appendingPathComponent("Likely")
        let real = dir.appendingPathComponent("Likely.noindex")
        try OwnerOnly.write("old\n", to: real.appendingPathComponent("likely.log"))
        try OwnerOnly.write("{\"a\":1}", to: real.appendingPathComponent("tools.json"))
        try OwnerOnly.write("x", to: real.appendingPathComponent("evals/cases.jsonl"))
        try OwnerOnly.write("new\n", to: folder.appendingPathComponent("likely.log"))
        try OwnerOnly.write("{\"b\":2}", to: folder.appendingPathComponent("tools.json"))
        try OwnerOnly.write("y", to: folder.appendingPathComponent("evals/drafts.jsonl"))
        try OwnerOnly.write("z", to: folder.appendingPathComponent("History/history.enc.jsonl"))
        _ = try OwnerOnly.createExclusive(folder.appendingPathComponent(".metadata_never_index"))

        XCTAssertEqual(try SpotlightExclusion.exclude(folder), .merged)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: folder.path), "Likely.noindex")
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("likely.log"), encoding: .utf8), "old\nnew\n", "logs appended")
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("tools.json"), encoding: .utf8), "{\"a\":1}")
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("tools.json.merged-1"), encoding: .utf8), "{\"b\":2}", "kept, not overwritten")
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("evals/cases.jsonl"), encoding: .utf8), "x")
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("evals/drafts.jsonl"), encoding: .utf8), "y")
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("History/history.enc.jsonl"), encoding: .utf8), "z")
        XCTAssertEqual(try SpotlightExclusion.exclude(folder), .alreadyExcluded)
    }

    /// The link's name was taken between the check and symlink(2) ("already exists"): a real folder
    /// there is merged rather than left split.
    func testFolderCreatedWhileLinkingIsMerged() throws {
        let folder = dir.appendingPathComponent("Logs/Likely")
        let real = dir.appendingPathComponent("Logs/Likely.noindex")
        // As if exclude had just made the target and a log write then created the folder.
        try OwnerOnly.write("early\n", to: folder.appendingPathComponent("likely.log"))
        try OwnerOnly.createDirectory(real)
        XCTAssertEqual(try SpotlightExclusion.exclude(folder), .merged)
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("likely.log"), encoding: .utf8), "early\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.path), "Likely.noindex")
    }

    func testLeavesForeignLinksAlone() throws {
        let folder = dir.appendingPathComponent("Likely")
        try OwnerOnly.createDirectory(folder)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Likely.noindex").path, contents: Data())
        guard case .skipped = try SpotlightExclusion.exclude(folder) else { return XCTFail("a file named like the target") }
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue)

        let other = dir.appendingPathComponent("Other")
        try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: "/tmp")
        guard case .skipped = try SpotlightExclusion.exclude(other) else { return XCTFail() }
    }
}

/// Whether a build encrypts, decided from entitlements and an injected probe: no keychain is touched.
final class EncryptionAvailabilityTests: XCTestCase {
    private func neverProbed(_ group: String) -> Result<Void, KeychainKeyStore.KeychainError> {
        XCTFail("probed \(group) without an access group entitlement")
        return .success(())
    }

    func testNoProvisioningProfileMeansOffWithoutProbing() {
        XCTAssertEqual(EncryptionAvailability.evaluate(SigningEntitlements(), probe: neverProbed), .off(.noProvisioningProfile))
        // Signed with a team but without keychain-access-groups (no profile): still off.
        let teamOnly = SigningEntitlements(applicationIdentifier: "ABCDE12345.inc.synth.likely", teamIdentifier: "ABCDE12345")
        XCTAssertEqual(EncryptionAvailability.evaluate(teamOnly, probe: neverProbed), .off(.noProvisioningProfile))
        // Only the profile's wildcard: no concrete group to use.
        let wildcard = SigningEntitlements(teamIdentifier: "ABCDE12345", keychainAccessGroups: ["ABCDE12345.*"])
        XCTAssertEqual(EncryptionAvailability.evaluate(wildcard, probe: neverProbed), .off(.noProvisioningProfile))
    }

    func testOnWithTheTeamsLikelyGroupFromTheEntitlements() {
        var probed: [String] = []
        let e = SigningEntitlements(applicationIdentifier: "ABCDE12345.inc.synth.likely", teamIdentifier: "ABCDE12345",
                                    keychainAccessGroups: ["ABCDE12345.other", "ABCDE12345.inc.synth.likely"])
        let state = EncryptionAvailability.evaluate(e) { probed.append($0); return .success(()) }
        XCTAssertEqual(state, .on(accessGroup: "ABCDE12345.inc.synth.likely"))
        XCTAssertEqual(probed, ["ABCDE12345.inc.synth.likely"])
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.summary, "Encryption: on")
    }

    /// A third-party build with its own team and bundle id uses its own group: nothing is hard-coded.
    func testAnotherTeamsGroup() {
        let e = SigningEntitlements(applicationIdentifier: "ZZZZZ99999.com.example.likely", keychainAccessGroups: ["ZZZZZ99999.com.example.likely"])
        XCTAssertEqual(e.team, "ZZZZZ99999")
        XCTAssertEqual(EncryptionAvailability.evaluate(e) { _ in .success(()) }, .on(accessGroup: "ZZZZZ99999.com.example.likely"))
    }

    /// With the entitlement, a Keychain that doesn't answer is an error state, never "off": the build
    /// still encrypts (keeps its access group), so nothing is written in plaintext.
    func testProbeFailureIsAnErrorNotOff() {
        let e = SigningEntitlements(teamIdentifier: "ABCDE12345", keychainAccessGroups: ["ABCDE12345.inc.synth.likely"])
        let state = EncryptionAvailability.evaluate(e) { _ in .failure(KeychainKeyStore.KeychainError(status: errSecInteractionNotAllowed)) }
        guard case .keychainError(let group, let why) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(group, "ABCDE12345.inc.synth.likely")
        XCTAssertTrue(why.contains("-25308"), why)
        XCTAssertFalse(state.isOn)
        XCTAssertTrue(state.encrypts)
        XCTAssertEqual(state.accessGroup, "ABCDE12345.inc.synth.likely")
        XCTAssertTrue(state.summary.contains("isn't answering"), state.summary)
        XCTAssertTrue(state.summary.contains("Nothing is saved unencrypted"), state.summary)
        // Retrying with the known group: back on once the probe works.
        XCTAssertEqual(EncryptionAvailability.evaluate(accessGroup: group) { _ in .success(()) }, .on(accessGroup: group))
        // Only a build without the entitlement keeps plaintext.
        XCTAssertFalse(EncryptionAvailability.off(.noProvisioningProfile).encrypts)
        XCTAssertTrue(EncryptionAvailability.on(accessGroup: group).encrypts)
    }

    func testOffSummaryNamesTheProfile() {
        XCTAssertEqual(EncryptionAvailability.off(.noProvisioningProfile).summary,
                       "Encryption: off in this build (no provisioning profile)")
    }

    /// The queries KeychainKeyStore sends (built, never run): data-protection keychain, the access
    /// group, this device only, not synced, no UI.
    func testKeychainQueriesUseTheDataProtectionKeychainWithoutUI() throws {
        let store = KeychainKeyStore(accessGroup: "ABCDE12345.inc.synth.likely")
        for query in [store.loadQuery, store.addQuery(Data(count: 32))] {
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "ABCDE12345.inc.synth.likely")
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
            XCTAssertTrue(context.interactionNotAllowed)
        }
        XCTAssertEqual(store.addQuery(Data(count: 32))[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
