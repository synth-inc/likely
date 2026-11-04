//
//  Permissions.swift
//  OnboardingKit
//
//  Check / request helpers for the macOS privacy permissions our apps ask for
//  (patterned on Onit's AccessibilityPermissionManager / ScreenRecordingPermissionManager).
//

import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

public enum Permissions {
    // MARK: Accessibility

    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (first time) and opens the Accessibility pane.
    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
    }

    // MARK: Screen Recording

    /// Note: macOS often only reports a fresh grant after the app relaunches.
    public static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    private static let screenRecordingAskedKey = "OnboardingKit.screenRecordingAsked"

    /// First time: touch ScreenCaptureKit, which makes macOS show its own "would like to record this
    /// screen" prompt (as Onit's ScreenRecordingPermissionManager does). After that macOS won't prompt
    /// again, so open System Settings instead. A grant usually only takes effect after a relaunch:
    /// pair this with `relaunch()`.
    public static func requestScreenRecording() {
        guard !screenRecordingGranted else { return }
        if UserDefaults.standard.bool(forKey: screenRecordingAskedKey) {
            openPrivacyPane("Privacy_ScreenCapture")
            return
        }
        UserDefaults.standard.set(true, forKey: screenRecordingAskedKey)
        Task {
            // Throws (or, on macOS 14+, returns limited content) without permission; either way the
            // system prompt has been triggered.
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    // MARK: Relaunch

    /// Quits and reopens the app, e.g. so a fresh Screen Recording grant takes effect.
    /// Apps should persist where the user is (onboarding step) before calling this.
    public static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
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
