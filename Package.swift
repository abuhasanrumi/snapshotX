// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnapKit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SnapKit", path: "Sources/SnapKit"),
        .testTarget(name: "SnapKitTests", dependencies: ["SnapKit"], path: "Tests/SnapKitTests"),
    ]
)
