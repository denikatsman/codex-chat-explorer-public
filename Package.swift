// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexChats",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "Prototypes/FlightRecorder"), .package(path: "Packages/WindowingKit")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CActiveJSON"),
        .target(name: "CMarkdown", exclude: ["LICENSE.md"], publicHeadersPath: "include"),
        .target(name: "CProcessIdentity", linkerSettings: [.linkedLibrary("proc")]),
        .target(name: "ModelSupport", dependencies: ["CProcessIdentity"]),
        .executableTarget(name: "ExplorerModelWorker", dependencies: ["ModelSupport"]),
        .executableTarget(name: "SemanticModelWorker", dependencies: ["ModelSupport"]),
        .executableTarget(name: "CodexChats", dependencies: [.product(name: "WindowingKit", package: "WindowingKit"), "CSQLite", "CActiveJSON", "CMarkdown", "ModelSupport", .product(name: "ExplorerDiagnosticsBridge", package: "FlightRecorder")]),
        .testTarget(name: "CodexChatsTests", dependencies: ["CodexChats", "CSQLite", "ModelSupport"])
    ]
)
