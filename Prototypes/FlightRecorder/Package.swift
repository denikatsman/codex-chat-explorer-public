// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FlightRecorder", platforms: [.macOS(.v13)], products: [
    .library(name: "FlightRecorder", targets: ["FlightRecorder"]),
    .library(name: "ExplorerDiagnosticsBridge", targets: ["ExplorerDiagnosticsBridge"]),
    .executable(name: "RecorderProbe", targets: ["RecorderProbe"])
], targets: [
    .target(name: "FRSystem", linkerSettings: [.linkedLibrary("proc")]),
    .target(name: "FlightRecorder", dependencies: ["FRSystem"]),
    .target(name: "ExplorerDiagnosticsBridge", dependencies: ["FlightRecorder"], path: "Integration"),
    .executableTarget(name: "RecorderProbe", dependencies: ["FlightRecorder"]),
    .testTarget(name: "FlightRecorderTests", dependencies: ["FlightRecorder"])
])
