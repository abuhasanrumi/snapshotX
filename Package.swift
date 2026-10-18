// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnapShotX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SnapShotX", path: "Sources/SnapShotX"),
        .testTarget(name: "SnapShotXTests", dependencies: ["SnapShotX"], path: "Tests/SnapShotXTests"),
    ]
)
