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
        // Eval case format, scoring and reports (Foundation only, unit-tested). See docs/EVALS.md.
        .target(name: "LikelyEvalKit", path: "Sources/LikelyEvalKit"),
        .testTarget(name: "LikelyEvalKitTests", dependencies: ["LikelyEvalKit"], path: "Tests/LikelyEvalKitTests"),
        .executableTarget(
            name: "Likely",
            dependencies: ["OnboardingKit", "LikelyEvalKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Likely",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    ]
)
