// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Rawgenzo",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RAWCore", targets: ["RAWCore"]),
        .library(name: "OperationSurface", targets: ["OperationSurface"]),
        .executable(name: "rawdev", targets: ["rawdev"]),
        .executable(name: "RawgenzoApp", targets: ["RawgenzoApp"]),
    ],
    targets: [
        // 現像エンジン本体(UI非依存)
        .target(name: "RAWCore"),
        // AI などに操作を委ねるための汎用の操作面(道具の定義・検証・権限・監査ログ・取り消し)。
        // Rawgenzo に依存しない(Foundation だけ)。他のソフトにも使えるようにするため RAWCore も import しない
        .target(name: "OperationSurface"),
        // Rawgenzo の写真・現像設定を操作面の道具として公開する(領域定義)
        .target(name: "RawgenzoSurface", dependencies: ["RAWCore", "OperationSurface"]),
        // サンプルRAWで動作確認するためのCLI
        .executableTarget(name: "rawdev", dependencies: ["RAWCore", "OperationSurface", "RawgenzoSurface"]),
        // SwiftUIの最小ビューア
        .executableTarget(name: "RawgenzoApp", dependencies: ["RAWCore"]),
        .testTarget(name: "RAWCoreTests", dependencies: ["RAWCore"]),
        .testTarget(name: "OperationSurfaceTests", dependencies: ["OperationSurface"]),
        .testTarget(name: "RawgenzoSurfaceTests", dependencies: ["RawgenzoSurface", "RAWCore", "OperationSurface"]),
    ]
)
