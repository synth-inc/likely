import AppKit
import OnboardingKit
import SwiftUI

enum LikelyOnboardingStep: String, Equatable {
    case welcome, permissions, folders, likelyFolder, agent, getAgent, license

    /// Where the user is, saved on every step change so a relaunch picks up where they left off, as
    /// in the Onit apps.
    static var saved: LikelyOnboardingStep {
        get { UserDefaults.standard.string(forKey: "onboardingStep").flatMap(Self.init) ?? .welcome }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "onboardingStep") }
    }

    static func clearSaved() { UserDefaults.standard.removeObject(forKey: "onboardingStep") }
}

/// Live permission / setup status, polled while onboarding (or Settings) is open.
final class SetupState: ObservableObject {
    @Published var accessibility = Permissions.accessibilityGranted
    @Published var folders: [SearchFolder] = SearchFolder.all
    @Published var folderAccess: [URL: Permissions.FolderAccess] = [:]
    @Published var likelyFolderExists = LikelyFolder.exists
    @Published var likelyFolderPath = ""
    @Published var likelyFolderPinned = false
    @Published var pinFailed = false

    func refresh() {
        accessibility = Permissions.accessibilityGranted
        let current = SearchFolder.all
        if current != folders { folders = current }
        for folder in folders { folderAccess[folder.url] = Permissions.folderAccess(folder.url) }
        likelyFolderExists = LikelyFolder.exists
        likelyFolderPath = (LikelyFolder.url.path as NSString).abbreviatingWithTildeInPath
        likelyFolderPinned = likelyFolderExists && SidebarFavorites.contains(LikelyFolder.url)
    }

    func pinLikelyFolder() {
        try? LikelyFolder.create()
        pinFailed = !SidebarFavorites.add(LikelyFolder.url)
        refresh()
    }

    func requestFolder(_ url: URL) {
        Permissions.requestFolderAccess(url) { [weak self] result in self?.folderAccess[url] = result }
    }

    /// "Add Folder…": pick a folder, then ask for access right away (protected locations prompt).
    func addCustomFolder() {
        guard let url = SearchFolder.chooseCustom() else { return }
        refresh()
        requestFolder(url)
    }

    func remove(_ folder: SearchFolder) {
        SearchFolder.removeCustom(folder)
        refresh()
    }
}

struct LikelyOnboardingView: View {
    @StateObject private var state = SetupState()
    @ObservedObject private var agents = AgentDetector.shared
    @State private var step: LikelyOnboardingStep = .saved
    @State private var hasCheckedInitially = false
    @State private var selectedAgent: String = Settings.agentID
    var onFinish: () -> Void

    var body: some View {
        ZStack {
            switch step {
            case .welcome: welcome.transition(.opacity)
            case .permissions: permissions.transition(.opacity)
            case .folders: folders.transition(.opacity)
            case .likelyFolder: likelyFolder.transition(.opacity)
            case .agent: agent.transition(.opacity)
            case .getAgent: getAgent.transition(.opacity)
            case .license: license.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .onChange(of: step) { _, newStep in LikelyOnboardingStep.saved = newStep }
        .onAppear {
            state.refresh()
            agents.scan()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { hasCheckedInitially = true }
        }
        .task {
            while !Task.isCancelled {
                state.refresh()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Welcome

    /// Bundled demo, if the build has one (Resources/likely-demo.mp4, copied in by build.sh).
    private var demoVideoURL: URL? { Bundle.main.url(forResource: "likely-demo", withExtension: "mp4") }

    /// Modeled on Onit's QuickEdit intro: title pill, headline, looping demo video.
    private var welcome: some View {
        OnboardingPage(
            nextButtonText: "Get Started",
            nextButtonIcon: "arrow.right",
            onNext: {
                // The footer's install-ID notice has been shown: the license server may now hear from us.
                Settings.sawServerNotice = true
                LicenseStore.shared.startPeriodicChecks()
                step = .permissions
            },
            headerContent: {
                OnboardingTitlePill(systemIcon: "doc.viewfinder", text: "Likely")
                OnboardingTitle("Why doesn't macOS do this?")
            },
            bodyContent: {
                OnboardingDemoVideo(url: demoVideoURL)
                    .padding(.top, 22)
                    .padding(.bottom, 24)
            },
            footerContent: { WelcomeLegalNotice() }
        )
    }

    // MARK: - Permissions

    private var permissions: some View {
        OnboardingPage(
            showBack: true,
            onBack: { step = .welcome },
            nextButtonText: "Continue",
            nextDisabled: !state.accessibility,
            onNext: { step = .folders },
            headerContent: {
                OnboardingTitle("Permissions", subtitle: "Likely needs one permission to work with file pickers.")
            },
            bodyContent: {
                VStack(alignment: .leading, spacing: 0) {
                    OnboardingPermissionRow(
                        icon: "accessibility", title: "Accessibility",
                        description: "Lets Likely notice when a file picker opens, and jump it to your Likely folder.",
                        isGranted: state.accessibility, shouldPulse: hasCheckedInitially,
                        action: Permissions.requestAccessibility)
                }
                .padding(.horizontal, 40)
                .padding(.top, 28)
            }
        )
    }

    // MARK: - Folders

    private var folders: some View {
        OnboardingPage(
            showBack: true,
            onBack: { step = .permissions },
            nextButtonText: "Continue",
            onNext: { step = .likelyFolder },
            headerContent: {
                OnboardingTitle("Let Likely search your files",
                                subtitle: "macOS asks once for each folder. Likely only reads;\nit never changes or deletes anything.")
            },
            bodyContent: {
                ScrollView {
                    SearchFolderList(state: state)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 4)
                }
                .padding(.top, 20)
            }
        )
    }

    // MARK: - Likely Folder

    private var likelyFolder: some View {
        OnboardingPage(
            showBack: true,
            onBack: { step = .folders },
            nextButtonText: "Continue",
            // Required: Likely jumps pickers to the folder by clicking its sidebar row.
            nextDisabled: !state.likelyFolderPinned,
            onNext: { step = .agent },
            headerContent: {
                OnboardingTitle("One folder, every file picker",
                                subtitle: "Likely puts its suggestions in a Likely folder.\nAdd it to your Finder sidebar so it's one click away in every picker.")
            },
            bodyContent: {
                // Fixed at ~/Likely: outside the macOS-protected folders, so it keeps working even if
                // folder access gets revoked, and never syncs to iCloud. Changeable in Settings.
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingPermissionRow(
                        icon: "sidebar.left", title: "Add to Finder sidebar", badge: "Required",
                        description: "Likely opens file pickers to your suggestions by clicking Likely in the picker's sidebar, so it needs to be under Favorites.",
                        isGranted: state.likelyFolderPinned, shouldPulse: hasCheckedInitially,
                        grantTitle: "Add to Sidebar",
                        action: state.pinLikelyFolder)
                    if state.pinFailed && !state.likelyFolderPinned {
                        // Fallback if the (deprecated) sidebar API ever stops working.
                        VStack(alignment: .leading, spacing: 8) {
                            instruction(1, "Couldn't add it automatically. Click **Show in Finder**.")
                            instruction(2, "Drag **\(LikelyFolder.url.lastPathComponent)** into **Favorites** in the Finder sidebar.")
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LikelyFolder.url]) }
                                .buttonStyle(.link)
                                .padding(.leading, 30)
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 28)
            }
        )
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.onboardingBlue300)
                .frame(width: 20, height: 20)
                .background(Color.onboardingBlue400.opacity(0.15), in: Circle())
            EditableText(text)
                .font(.system(size: 13))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
        }
    }

    // MARK: - Agent

    private var supportedInstalled: [AgentKind] { agents.installed.filter(\.isSupported) }

    private var agent: some View {
        OnboardingPage(
            showBack: true,
            onBack: { step = .likelyFolder },
            nextButtonText: supportedInstalled.isEmpty ? "Get an Agent" : (License.isFreeBuild ? "Finish" : "Continue"),
            nextDisabled: agents.isScanning,
            onNext: {
                if let chosen = AgentKind.with(id: selectedAgent), chosen.isSupported, agents.path(for: chosen) != nil {
                    Settings.agentID = chosen.id
                    if License.isActive { onFinish() } else { step = .license }
                } else {
                    step = .getAgent
                }
            },
            headerContent: {
                OnboardingTitle("Choose your agent",
                                subtitle: "Likely uses a coding agent already on your Mac to find files.\nIt runs with read-only tools and uses your own account.")
            },
            bodyContent: {
                VStack(alignment: .leading, spacing: 10) {
                    if agents.isScanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            EditableText("Looking for coding agents…").foregroundColor(.secondary)
                        }
                    } else if agents.installed.isEmpty {
                        EditableText("No coding agents found on this Mac.").foregroundColor(.secondary)
                    } else {
                        ForEach(agents.installed) { kind in agentRow(kind) }
                    }
                    // With nothing installed the footer button already says "Get an Agent"; keep the link plain.
                    Button(agents.installed.isEmpty ? "Get an agent →" : "Don't see yours? Get an agent →") { step = .getAgent }
                        .buttonStyle(.link)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 80)
                .padding(.top, 26)
                .onChange(of: agents.isScanning) { _, scanning in
                    // Preselect the first supported agent we found.
                    if !scanning, AgentKind.with(id: selectedAgent).flatMap(agents.path(for:)) == nil,
                       let first = supportedInstalled.first {
                        selectedAgent = first.id
                    }
                }
            }
        )
    }

    private func agentRow(_ kind: AgentKind) -> some View {
        let selected = selectedAgent == kind.id
        return Button {
            if kind.isSupported { selectedAgent = kind.id }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(kind.isSupported ? .onboardingBlue300 : .secondary)
                HStack(spacing: 6) {
                    Text(kind.name).font(.system(size: 14, weight: .medium))
                    Text(kind.maker).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                EditableText(kind.isSupported ? "Ready" : "Coming soon")
                    .font(.system(size: 12))
                    .foregroundColor(kind.isSupported ? .green : .secondary)
            }
            .padding(10)
            .background(selected ? Color.onboardingBlue400.opacity(0.15) : Color.onboardingFillQuiet,
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(kind.isSupported ? 1 : 0.6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - License (Option D: the "vote" as a toggle, one offer at a time)

    @State private var keepImproving = true
    @State private var showFontTweaker = false
    @ObservedObject private var copyEditor = CopyEditor.shared
    @ObservedObject private var licenseStore = LicenseStore.shared
    /// Asking the server for a Checkout session.
    @State private var openingCheckout = false
    /// Checkout is open in the browser; poll entitlements until it lands (or the deep link arrives).
    @State private var waitingForCheckout = false
    @State private var checkoutURL: URL?
    @State private var restoring = false
    /// Errors and "nothing found" from Subscribe / Buy Once / Restore.
    @State private var licenseMessage: String?

    private var licensed: Bool { licenseStore.isActive }

    private var offeredPlan: License.Plan {
        let kind: License.Kind = keepImproving ? .subscription : .oneTime
        return License.plans.first { $0.kind == kind }!
    }

    private var license: some View {
        OnboardingPage(
            showBack: true,
            onBack: { step = .agent },
            nextButtonText: "Finish",
            nextDisabled: !licensed,
            onNext: onFinish,
            headerContent: {
                OnboardingTitle("We couldn't decide on a business model…",
                                subtitle: "So we decided to leave it to you. Take your pick.")
            },
            bodyContent: {
                VStack(spacing: 14) {
                    voteToggle
                    offer
                    if licensed {
                        Label("License active. You're all set.", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.green)
                    } else if waitingForCheckout {
                        checkoutWaiting
                    }
                    if !licensed, let licenseMessage {
                        Text(licenseMessage)
                            .font(.system(size: 12))
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .multilineTextAlignment(.center)
                            .frame(width: 420)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if !licensed { buildItYourselfLink.padding(.bottom, 16) }
                }
                .frame(maxHeight: .infinity)
                .padding(.top, 18)
                .task(id: waitingForCheckout) { await pollWhileWaiting() }
                .onChange(of: licensed) { _, active in if active { waitingForCheckout = false } }
            },
            footerContent: {
                HStack(spacing: 14) {
                    if !licensed {
                        Button(action: restore) {
                            (Text(copyEditor.text("Already bought it?")).foregroundColor(Color(NSColor.secondaryLabelColor))
                             + Text(" ") + Text(copyEditor.text("Restore")).underline())
                                .font(.system(size: 12))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(restoring)
                        if restoring { ProgressView().controlSize(.small) }
                    }
                    LegalLinks()
                    if copyEditor.isEnabled {
                        Button("Aa Fonts") { showFontTweaker.toggle() }
                            .popover(isPresented: $showFontTweaker, arrowEdge: .top) {
                                StyleTweaker(title: "License page fonts", prefix: "license.", controls: Self.fontControls)
                            }
                    }
                }
                .padding(.leading, 12)
            }
        )
    }

    /// The two plans' headlines: subscription vs one-time.
    private var voteToggle: some View {
        HStack(spacing: 0) {
            voteSegment(License.plans[0].headline, selected: keepImproving) { keepImproving = true }
            voteSegment(License.plans[1].headline, selected: !keepImproving) { keepImproving = false }
        }
        .padding(3)
        .background(Color.onboardingFillQuiet, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.15), value: keepImproving)
    }

    private func voteSegment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(copyEditor.text(title))
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundColor(selected ? .white : Color(NSColor.secondaryLabelColor))
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background(selected ? Color.onboardingBlue400 : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var offer: some View {
        let plan = offeredPlan
        return VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                EditableText(plan.price)
                    .font(font(Self.priceStyle))
                    .foregroundColor(Color(NSColor.labelColor))
                    .fixedSize()
                EditableText(plan.priceUnit)
                    .font(font(Self.unitStyle))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .center)
            EditableText(plan.detail)
                .font(font(Self.detailStyle))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .multilineTextAlignment(.center)
                .frame(width: 420)
                .fixedSize(horizontal: false, vertical: true)
            if let disclosure = plan.disclosure {
                Text(disclosure)   // legal copy: not copy-editable
                    .font(.system(size: 11))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .multilineTextAlignment(.center)
                    .frame(width: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if licensed && licenseStore.activeKind == plan.kind {
                    Label("Active", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.green)
                } else {
                    OnboardingNextButton(text: plan.buttonTitle, disabled: licensed || openingCheckout) { choose(plan) }
                }
            }
            .padding(.top, 8)
        }
    }

    /// Pinned just above the footer, like the "try it" line on QuickEdit's onboarding.
    private var buildItYourselfLink: some View {
        Button {
            NSWorkspace.shared.open(License.sourceURL)
        } label: {
            (Text(copyEditor.text("Allergic to paying?")).foregroundColor(Color(NSColor.secondaryLabelColor))
             + Text(" ") + Text(copyEditor.text("Build it from GitHub")).underline())
                .font(.system(size: 12))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var checkoutWaiting: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            EditableText("Finish checkout in your browser…")
                .font(.system(size: 13))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
            if let checkoutURL {
                Button("Reopen") { NSWorkspace.shared.open(checkoutURL) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
    }

    /// Asks the server for a Stripe Checkout session, opens it, and starts waiting for the purchase.
    private func choose(_ plan: License.Plan) {
        openingCheckout = true
        licenseMessage = nil
        Task {
            defer { openingCheckout = false }
            do {
                let url = try await licenseStore.checkoutURL(for: plan)
                checkoutURL = url
                NSWorkspace.shared.open(url)
                waitingForCheckout = true
            } catch {
                licenseMessage = error.localizedDescription
            }
        }
    }

    /// While checkout is open, re-check every few seconds so we finish even if the
    /// `likely://payment-success` redirect never reaches us. Gives up after 20 minutes.
    private func pollWhileWaiting() async {
        guard waitingForCheckout else { return }
        let deadline = Date().addingTimeInterval(20 * 60)
        while !Task.isCancelled, waitingForCheckout, !licensed, Date() < deadline {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            await licenseStore.refresh()
        }
        if !licensed, waitingForCheckout {
            waitingForCheckout = false
            licenseMessage = "Didn't see a purchase yet. If you finished checkout, click Restore."
        }
    }

    /// Re-checks entitlements for this Mac's account.
    /// TODO: device-login accounts are per install, so a purchase made on another Mac (or before a
    /// reinstall that lost the installId) won't show up here. Real restore needs email login.
    private func restore() {
        restoring = true
        licenseMessage = nil
        Task {
            let active = await licenseStore.refresh()
            restoring = false
            if !active {
                licenseMessage = licenseStore.lastError
                    ?? "No purchase found for this Mac. Purchases are tied to the Mac you bought on for now; if you bought on another Mac, contact us and we'll sort it out."
            }
        }
    }

    // Offer text styles, tweakable live with the Fonts panel while copy editing is on.
    private static let priceStyle = (prefix: "license.price", size: 40.0, weight: Font.Weight.semibold)
    private static let unitStyle = (prefix: "license.unit", size: 15.0, weight: Font.Weight.regular)
    private static let detailStyle = (prefix: "license.detail", size: 13.0, weight: Font.Weight.regular)

    private static var fontControls: [StyleControl] {
        StyleOptions.controls(priceStyle.prefix, label: "Price", size: priceStyle.size, weight: priceStyle.weight)
            + StyleOptions.controls(unitStyle.prefix, label: "Per month", size: unitStyle.size, weight: unitStyle.weight)
            + StyleOptions.controls(detailStyle.prefix, label: "Detail", size: detailStyle.size, weight: detailStyle.weight)
    }

    private func font(_ style: (prefix: String, size: Double, weight: Font.Weight)) -> Font {
        StyleOptions.font(style.prefix, size: style.size, weight: style.weight)
    }

    // MARK: - Get an Agent (placeholder)

    private var getAgent: some View {
        OnboardingPage(
            showBack: true,
            onBack: { step = .agent },
            nextButtonText: "Check Again",
            onNext: {
                agents.scan()
                step = .agent
            },
            headerContent: {
                OnboardingTitle("Get a coding agent",
                                subtitle: "Install one of these in Terminal, sign in once, then come back.\n(Placeholder: guided setup coming soon.)")
            },
            bodyContent: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(AgentKind.all) { kind in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(kind.name).font(.system(size: 13, weight: .medium))
                                    EditableText(kind.isSupported ? "Works today" : "Coming soon")
                                        .font(.system(size: 11)).foregroundColor(kind.isSupported ? .green : .secondary)
                                    Spacer()
                                    Link("Website", destination: kind.homepage).font(.system(size: 12))
                                }
                                HStack {
                                    Text(kind.installCommand)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(kind.installCommand, forType: .string)
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .padding(8)
                            .background(Color.onboardingFillQuiet, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 60)
                }
                .padding(.top, 16)
            }
        )
    }
}

/// Rows for every search folder, with "Add Folder…" at the bottom. Shared by onboarding and Settings.
struct SearchFolderList: View {
    @ObservedObject var state: SetupState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(state.folders) { folder in
                let access = state.folderAccess[folder.url] ?? .notRequested
                HStack(alignment: .center, spacing: 6) {
                    OnboardingPermissionRow(
                        icon: folder.icon, title: folder.name, badge: folder.isCustom ? nil : "Recommended",
                        description: folder.why,
                        isGranted: access == .granted, shouldPulse: false,
                        grantTitle: access == .denied ? "Open Settings" : "Allow",
                        action: { state.requestFolder(folder.url) })
                    if folder.isCustom {
                        Button {
                            state.remove(folder)
                        } label: {
                            Image(systemName: "minus.circle").foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop searching this folder")
                    }
                }
            }
            Button {
                state.addCustomFolder()
            } label: {
                Label("Add Folder…", systemImage: "plus")
                    .font(.system(size: 13))
            }
            .buttonStyle(.link)
            .padding(.leading, 30)
        }
    }
}
