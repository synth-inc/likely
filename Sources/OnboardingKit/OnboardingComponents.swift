//
//  OnboardingComponents.swift
//  OnboardingKit (from DockLock)
//

import SwiftUI

// MARK: - Title Pill

public struct OnboardingTitlePill: View {
    let systemIcon: String
    let text: String

    public init(systemIcon: String, text: String) {
        self.systemIcon = systemIcon
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: systemIcon)
                .font(.system(size: 12))
                .foregroundColor(Color.onboardingBlue300)

            EditableText(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.onboardingBlue300)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.onboardingBlue400.opacity(0.15))
        .clipShape(Capsule())
    }
}

// MARK: - Feature Row

public struct OnboardingFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    public init(icon: String, title: String, description: String) {
        self.icon = icon
        self.title = title
        self.description = description
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(Color.onboardingBlue300)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                EditableText(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(NSColor.labelColor))

                EditableText(description)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Permission Row

/// One permission: icon, name, Required/Optional badge, why it's needed, and a grant button.
/// (Generalized from DockLock's accessibility row.)
public struct OnboardingPermissionRow: View {
    let icon: String
    let title: String
    let badge: String?
    let description: String
    let isGranted: Bool
    let shouldPulse: Bool
    let grantTitle: String
    let note: String?
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?
    let infoLinkTitle: String?
    let infoAction: (() -> Void)?
    let action: () -> Void

    public init(
        icon: String,
        title: String,
        badge: String? = "Required",
        description: String,
        isGranted: Bool,
        shouldPulse: Bool,
        grantTitle: String = "Grant Access",
        note: String? = nil,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        infoLinkTitle: String? = nil,
        infoAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.badge = badge
        self.description = description
        self.isGranted = isGranted
        self.shouldPulse = shouldPulse
        self.grantTitle = grantTitle
        self.note = note
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
        self.infoLinkTitle = infoLinkTitle
        self.infoAction = infoAction
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(Color(NSColor.labelColor))
                        .frame(width: 22, height: 22)

                    EditableText(title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(Color(NSColor.labelColor))

                    if let badge {
                        EditableText(badge)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                            .background(Color.onboardingFill)
                            .cornerRadius(6)
                    }
                }

                EditableText(description)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .padding(.leading, 30)
                    .fixedSize(horizontal: false, vertical: true)

                // Onit's "(See how)": opens an explainer for permissions that need convincing.
                if let infoLinkTitle, let infoAction {
                    Button(action: infoAction) {
                        Text(infoLinkTitle)
                            .underline()
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(Color.onboardingS0)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.leading, 30)
                }

                if !isGranted, note != nil || secondaryTitle != nil {
                    HStack(spacing: 6) {
                        if let note {
                            EditableText(note)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(Color(NSColor.secondaryLabelColor))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let secondaryTitle, let secondaryAction {
                            Button(secondaryTitle, action: secondaryAction)
                                .buttonStyle(.link)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .padding(.leading, 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            OnboardingPulsingButton(
                text: isGranted ? "Granted" : grantTitle,
                isGranted: isGranted,
                shouldPulse: shouldPulse && !isGranted,
                action: action
            )
        }
    }
}

// MARK: - Pulsing Permission Button

public struct OnboardingPulsingButton: View {
    let text: String
    let isGranted: Bool
    let shouldPulse: Bool
    let action: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var pulseTimer: Timer?
    @State private var isHovered: Bool = false

    public init(text: String, isGranted: Bool, shouldPulse: Bool, action: @escaping () -> Void) {
        self.text = text
        self.isGranted = isGranted
        self.shouldPulse = shouldPulse
        self.action = action
    }

    public var body: some View {
        Button {
            if !isGranted { action() }
        } label: {
            HStack(alignment: .center, spacing: 6) {
                Text(text)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(shouldPulse && !isGranted ? .white : Color(NSColor.labelColor))

                if isGranted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(NSColor.labelColor))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 37)
            .background(buttonBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isGranted ? Color(NSColor.separatorColor) : Color.clear, lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isGranted)
        .allowsHitTesting(!isGranted)
        .scaleEffect(scale)
        .onChange(of: shouldPulse) { _, newValue in
            if newValue { startPulse() } else { stopPulse() }
        }
        .onAppear { if shouldPulse { startPulse() } }
        .onDisappear { stopPulse() }
        .onHover { isHovered = $0 }
    }

    private var buttonBackground: Color {
        if isGranted { return .clear }
        if shouldPulse {
            return isHovered ? Color.onboardingBlue400.opacity(0.75) : Color.onboardingBlue400
        }
        return isHovered ? Color.onboardingFill : Color.onboardingFillQuiet
    }

    private func startPulse() {
        stopPulse()
        performPulse()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            performPulse()
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        withAnimation(.easeOut(duration: 0.15)) { scale = 1.0 }
    }

    private func performPulse() {
        withAnimation(.easeOut(duration: 0.12)) { scale = 1.08 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.15)) { scale = 1.0 }
        }
    }
}
