// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowingKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WindowingKit", targets: ["WindowingKit"])],
    targets: [
        .target(name: "WindowingKit"),
        .testTarget(name: "WindowingKitTests", dependencies: ["WindowingKit"])
    ]
)
