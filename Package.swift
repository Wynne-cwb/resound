// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Resound",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "resound", targets: ["resound"]),
        .library(name: "ResoundCore", targets: ["ResoundCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ResoundCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "resound",
            dependencies: [
                "ResoundCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
