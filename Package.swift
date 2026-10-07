// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Rawgenzo",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RAWCore", targets: ["RAWCore"]),
        .executable(name: "rawdev", targets: ["rawdev"]),
        .executable(name: "RawgenzoApp", targets: ["RawgenzoApp"]),
    ],
    targets: [
        // 現像エンジン本体(UI非依存)
        .target(name: "RAWCore"),
        // サンプルRAWで動作確認するためのCLI
        .executableTarget(name: "rawdev", dependencies: ["RAWCore"]),
        // SwiftUIの最小ビューア
        .executableTarget(name: "RawgenzoApp", dependencies: ["RAWCore"]),
        .testTarget(name: "RAWCoreTests", dependencies: ["RAWCore"]),
    ]
)
