//
//  OnboardingStyles.swift
//  OnboardingKit (from DockLock)
//

import AppKit
import SwiftUI

// MARK: - Visual Effect View

public struct VisualEffectView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material

    public init(material: NSVisualEffectView.Material = .hudWindow) {
        self.material = material
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - Color Extensions

public extension Color {
    static let onboardingBlue300 = Color(red: 0.51, green: 0.69, blue: 1.0)
    static let onboardingBlue350 = Color(red: 0.36, green: 0.59, blue: 0.98)
    static let onboardingBlue400 = Color(red: 0.22, green: 0.49, blue: 0.96)

    // Onit's asset-catalog colors (display P3, light / dark), so onboarding matches the Onit apps.
    /// Onit "Surface2": near-opaque panel laid over the HUD blur.
    static let onboardingSurface = dynamic(light: (0xF5, 0xF5, 0xF5, 0.95), dark: (0x16, 0x17, 0x1A, 0.95))
    /// Onit "Smoke": opaque footer.
    static let onboardingSmoke = dynamic(light: (0xF5, 0xF5, 0xF5, 1), dark: (0x16, 0x17, 0x1A, 1))
    /// Onit "T4": dotted footer divider.
    static let onboardingDivider = dynamic(light: (0x5D, 0x65, 0x78, 0.4), dark: (0xE9, 0xEF, 0xFF, 0.4))
    /// Onit "T8": badges, pressed fills.
    static let onboardingFill = dynamic(light: (0x70, 0x73, 0x7A, 0.16), dark: (0xDD, 0xE3, 0xFF, 0.15))
    /// Onit "S0": pure black / white, used at low opacity for outlines.
    static let onboardingS0 = dynamic(light: (0, 0, 0, 1), dark: (0xFF, 0xFF, 0xFF, 1))
    /// Onit "T9": quiet button and card fills.
    static let onboardingFillQuiet = dynamic(light: (0x70, 0x73, 0x7A, 0.10), dark: (0xE0, 0xE5, 0xFF, 0.10))

    private typealias RGBA = (r: Int, g: Int, b: Int, a: CGFloat)

    private static func dynamic(light: RGBA, dark: RGBA) -> Color {
        Color(NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(displayP3Red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: c.a)
        })
    }
}

// MARK: - Dotted Line (Onit's Line)

public struct OnboardingDottedLine: View {
    var color: Color

    public init(color: Color = .onboardingDivider) {
        self.color = color
    }

    public var body: some View {
        LineShape()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
            .frame(height: 1)
            .foregroundColor(color)
    }

    private struct LineShape: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

// MARK: - Text Styles

public struct OnboardingTitle: View {
    let title: String
    let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .center, spacing: 11) {
            EditableText(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Color(NSColor.labelColor))
                .multilineTextAlignment(.center)

            if let subtitle {
                EditableText(subtitle)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 40)
    }
}
