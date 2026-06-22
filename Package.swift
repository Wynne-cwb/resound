// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Resound",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "resound", targets: ["resound"]),
        .executable(name: "ResoundApp", targets: ["ResoundApp"]),
        .library(name: "ResoundCore", targets: ["ResoundCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "CSQLiteVec",
            cSettings: [.define("SQLITE_CORE")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // sherpa-onnx 声纹 C API：链接 Vendor 下的纯静态库（由 scripts/build-sherpa-onnx.sh 生成）。
        .target(
            name: "CSherpaOnnx",
            cSettings: [.unsafeFlags(["-I", "Vendor/sherpa-onnx/include"])],
            linkerSettings: [
                .unsafeFlags(["-L", "Vendor/sherpa-onnx/lib", "-lsherpa-onnx", "-lonnxruntime"]),
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "ResoundCore",
            dependencies: [
                "CSQLiteVec",
                "CSherpaOnnx",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.copy("Resources/TSCharacters.txt")],
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
        .executableTarget(
            name: "ResoundApp",
            dependencies: [
                "ResoundCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
