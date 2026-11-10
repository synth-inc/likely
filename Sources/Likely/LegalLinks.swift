import SwiftUI

/// "Terms · Privacy Policy" links to the site, for onboarding, the purchase screen and Settings.
struct LegalLinks: View {
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            Link("Terms", destination: License.termsURL)
            Text("·").foregroundColor(Color(NSColor.tertiaryLabelColor))
            Link("Privacy Policy", destination: License.privacyURL)
        }
        .font(.system(size: size))
        // Quiet grey links, not accent blue.
        .foregroundStyle(Color(NSColor.secondaryLabelColor))
        .tint(Color(NSColor.secondaryLabelColor))
    }
}

/// The first onboarding screen's notice: continuing means agreeing to the Terms (the license server is
/// only contacted after this screen; the Privacy Policy describes the install ID). Free builds never
/// talk to the server, so they only get the links.
struct WelcomeLegalNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !License.isFreeBuild {
                Text("By continuing, you agree to the Terms and Privacy Policy.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            LegalLinks(size: 11)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}
