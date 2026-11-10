//
//  Permissions.swift
//  OnboardingKit
//
//  Check / request helpers for the macOS privacy permissions our apps ask for
//  (patterned on Onit's AccessibilityPermissionManager).
//

import AppKit
import ApplicationServices

public enum Permissions {
    // MARK: Accessibility

    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (first time) and opens the Accessibility pane.
    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
    }

    // MARK: Files & Folders

    public enum FolderAccess: Equatable {
        /// Never asked (reading it would show the system prompt).
        case notRequested
        case granted
        case denied
    }

    private static func requestedKey(_ url: URL) -> String { "OnboardingKit.folderRequested.\(url.path)" }

    /// Checks without triggering a prompt: folders we haven't asked about yet report `.notRequested`.
    public static func folderAccess(_ url: URL) -> FolderAccess {
        guard UserDefaults.standard.bool(forKey: requestedKey(url)) else { return .notRequested }
        return canRead(url) ? .granted : .denied
    }

    /// Reading a protected folder (Desktop, Documents, Downloads, …) is what makes macOS show
    /// "would like to access files in your … folder". The read blocks until the user answers,
    /// so it runs off the main thread. If they said no before, macOS won't ask again: open Settings.
    public static func requestFolderAccess(_ url: URL, completion: @escaping (FolderAccess) -> Void) {
        let alreadyAsked = UserDefaults.standard.bool(forKey: requestedKey(url))
        UserDefaults.standard.set(true, forKey: requestedKey(url))
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = canRead(url)
            DispatchQueue.main.async {
                if !granted && alreadyAsked { openPrivacyPane("Privacy_FilesAndFolders") }
                completion(granted ? .granted : .denied)
            }
        }
    }

    private static func canRead(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    // MARK: Settings

    /// macOS 26 moved Privacy & Security to a new settings extension ID (as in Onit).
    public static func openPrivacyPane(_ anchor: String) {
        let base: String
        if #available(macOS 26, *) {
            base = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        } else {
            base = "x-apple.systempreferences:com.apple.preference.security"
        }
        if let url = URL(string: "\(base)?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
