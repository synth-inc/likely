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
        // User-added agent tools (tools.json): model, validation, permission mapping, prompts. Foundation
        // only, unit-tested. See docs/TOOLS.md.
        .target(name: "LikelyTools", path: "Sources/LikelyTools"),
        .testTarget(name: "LikelyToolsTests", dependencies: ["LikelyTools"], path: "Tests/LikelyToolsTests"),
        .executableTarget(
            name: "Likely",
            dependencies: ["OnboardingKit", "LikelyTools", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Likely",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    ]
)
