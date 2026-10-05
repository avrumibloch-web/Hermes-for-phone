// swift-tools-version: 6.0
import PackageDescription

// HermesKit is the agent harness: memory, skills, session search, cron, context budgeting,
// the tool loop around Apple's Foundation Models, and the device tools. The iOS app in App/
// is a thin SwiftUI + App Intents shell on top of it.
let package = Package(
    name: "HermesKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "HermesKit", targets: ["HermesKit"]),
    ],
    targets: [
        .target(
            name: "HermesKit",
            resources: [
                .copy("Resources/BundledSkills"),
                .copy("Resources/SOUL.md"),
            ]
        ),
        .testTarget(
            name: "HermesKitTests",
            dependencies: ["HermesKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
