// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Likely",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OnboardingKit", targets: ["OnboardingKit"]),
    ],
    targets: [
        // Reusable onboarding UI + permission helpers (from DockLock / Onit). Meant to move to its own
        // package once a second app adopts it.
        .target(name: "OnboardingKit", path: "Sources/OnboardingKit"),
        .executableTarget(name: "Likely", dependencies: ["OnboardingKit"], path: "Sources/Likely"),
    ]
)
