// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Likely",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OnboardingKit", targets: ["OnboardingKit"]),
    ],
    dependencies: [
        // Auto-updates. build.sh embeds Sparkle.framework in Likely.app/Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Reusable onboarding UI + permission helpers (from DockLock / Onit). Meant to move to its own
        // package once a second app adopts it.
        .target(name: "OnboardingKit", path: "Sources/OnboardingKit"),
        // Foundation-only rules for picking recent files (batches, files apps write in the background),
        // split out so they can be unit tested.
        .target(name: "RecentFilesCore", path: "Sources/RecentFilesCore"),
        .executableTarget(
            name: "Likely",
            dependencies: ["OnboardingKit", "RecentFilesCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Likely",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "RecentFilesCoreTests", dependencies: ["RecentFilesCore"], path: "Tests/RecentFilesCoreTests"),
    ]
)
