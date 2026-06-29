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
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
        // 锁 <0.10.2：0.10.2 起需 swift-tools-version 6.1（用了 6.1 才有的 withThrowingTaskGroup 无 of: 重载），
        // 当前工具链 Swift 6.0.3 编不过。0.10.1 是最后一个 swift-tools 6.0 兼容版。
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", "0.9.0"..<"0.10.2"),
        // 自定义 stdio 子进程 Transport 需符合 swift-sdk 的 Transport 协议（logger: Logging.Logger）。
        // swift-sdk 已传递依赖 swift-log；这里显式声明以便 ResoundCore `import Logging`。
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
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
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
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
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [.copy("Resources/MCPIcons")],   // MCP 来源品牌图标（SVG，NSImage 原生渲染）
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
