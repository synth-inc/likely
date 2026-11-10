// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Likely",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OnboardingKit", targets: ["OnboardingKit"]),
        .library(name: "LikelyEvalKit", targets: ["LikelyEvalKit"]),
    ],
    dependencies: [
        // Auto-updates. build.sh embeds Sparkle.framework in Likely.app/Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Reusable onboarding UI + permission helpers (from DockLock / Onit). Meant to move to its own
        // package once a second app adopts it.
        .target(name: "OnboardingKit", path: "Sources/OnboardingKit"),
        // Owner-only files, the data key (Keychain) and AES-GCM encryption of history, Spotlight
        // exclusion, the cleanup of older versions' screenshots. Foundation/CryptoKit/Security only, unit-tested with an
        // in-memory key. See docs/PRIVACY.md.
        .target(name: "LikelyStorage", path: "Sources/LikelyStorage"),
        .testTarget(name: "LikelyStorageTests", dependencies: ["LikelyStorage"], path: "Tests/LikelyStorageTests"),
        // Eval case format, scoring and reports (Foundation only, unit-tested). See docs/EVALS.md.
        .target(name: "LikelyEvalKit", dependencies: ["LikelyStorage"], path: "Sources/LikelyEvalKit"),
        .testTarget(name: "LikelyEvalKitTests", dependencies: ["LikelyEvalKit", "LikelyStorage"], path: "Tests/LikelyEvalKitTests"),
        // User-added agent tools (tools.json): model, validation, permission mapping, prompts. Foundation
        // only, unit-tested. See docs/TOOLS.md. Uses LikelyEvalKit for the search history's location
        // (AgentSandbox denies it to agents).
        .target(name: "LikelyTools", dependencies: ["LikelyEvalKit", "LikelyStorage"], path: "Sources/LikelyTools"),
        .testTarget(name: "LikelyToolsTests", dependencies: ["LikelyTools", "LikelyStorage"], path: "Tests/LikelyToolsTests"),
        // Foundation-only rules for picking recent files (batches, files apps write in the background),
        // split out so they can be unit tested.
        .target(name: "RecentFilesCore", path: "Sources/RecentFilesCore"),
        .executableTarget(
            name: "Likely",
            dependencies: ["OnboardingKit", "LikelyEvalKit", "LikelyStorage", "LikelyTools", "RecentFilesCore",
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Likely",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "RecentFilesCoreTests", dependencies: ["RecentFilesCore"], path: "Tests/RecentFilesCoreTests"),
    ]
)
