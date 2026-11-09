import AppKit
import Combine
import Sparkle

/// Sparkle auto-updates. The feed (SUFeedURL) and EdDSA public key (SUPublicEDKey) live in Info.plist;
/// releases are cut with scripts/release.sh.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var canCheckForUpdates = false

    /// Sparkle's own preference (SUEnableAutomaticChecks in UserDefaults; Info.plist sets the default).
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    /// Updates are for paid builds: every paid license (subscription or one-time) gets them, and
    /// nothing here looks at the plan. Free builds (LIKELY_FREE) never touch the paid feed (build.sh
    /// also strips SUFeedURL from their Info.plist), and builds without a feed (the bare
    /// `.build/release/Likely` binary) would only show Sparkle errors. Dev builds (LIKELY_DEV) are off
    /// too (build.sh strips their feed as well), so Sparkle never offers to replace one with a release.
    nonisolated static var isEnabled: Bool {
        #if LIKELY_DEV
        return false
        #else
        return !License.isFreeBuild && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        #endif
    }

    /// Starts the updater (scheduled background checks). Call once at launch.
    func start() {
        guard Self.isEnabled else {
            Log.write("update", License.isFreeBuild ? "free build; updates disabled"
                      : "dev build or no SUFeedURL in Info.plist; updates disabled")
            return
        }
        controller.startUpdater()
        Log.write("update", "updater started, feed \(public: controller.updater.feedURL?.absoluteString)")
    }

    func checkForUpdates() {
        guard Self.isEnabled else { return }
        // Likely is a menu bar (accessory) app: bring Sparkle's window to the front.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
