// swift-tools-version: 6.2
import PackageDescription

// HermesKit is the agent harness: memory, skills, session search, cron, context budgeting,
// the tool loop around Apple's Foundation Models, and the device tools.
// HermesLocalModels adds open-weight models (Qwen3 etc.) run locally with MLX, through
// Apple's MLXFoundationModels adapter. It's a separate target so the core harness builds
// without the MLX packages.
// The iOS and macOS apps in App/ are thin SwiftUI + App Intents shells on top.
let package = Package(
    name: "HermesKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "HermesKit", targets: ["HermesKit"]),
        .library(name: "HermesLocalModels", targets: ["HermesLocalModels"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "HermesKit",
            resources: [
                .copy("Resources/BundledSkills"),
                .copy("Resources/SOUL.md"),
            ]
        ),
        .target(
            name: "HermesLocalModels",
            dependencies: [
                "HermesKit",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .testTarget(
            name: "HermesKitTests",
            dependencies: ["HermesKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
