// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UniveEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UniveEngineKit", targets: ["UniveEngineKit"]),
        .executable(name: "unive", targets: ["unive"]),
    ],
    targets: [
        .target(name: "UniveEngineKit"),
        // `unive`: runs Windows programs the way UniveGame does, so changes can be tried without the app.
        .target(name: "UniveCommand", dependencies: ["UniveEngineKit"]),
        .executableTarget(name: "unive", dependencies: ["UniveCommand"]),
        .testTarget(
            name: "UniveEngineKitTests",
            dependencies: ["UniveEngineKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "UniveCommandTests", dependencies: ["UniveCommand"]),
    ]
)
