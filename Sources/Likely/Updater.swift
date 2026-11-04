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

    /// Starts the updater (scheduled background checks). Call once at launch. Skipped without a feed in
    /// Info.plist, e.g. the bare `.build/release/Likely` debug binary, where Sparkle would show an error.
    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            Log.write("update", "no SUFeedURL in Info.plist; updates disabled")
            return
        }
        controller.startUpdater()
        Log.write("update", "updater started, feed \(controller.updater.feedURL?.absoluteString ?? "none")")
    }

    func checkForUpdates() {
        // Likely is a menu bar (accessory) app: bring Sparkle's window to the front.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
