// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LockIn",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LockIn", targets: ["LockIn"])],
    targets: [
        .target(name: "LockInCore"),
        .executableTarget(name: "LockIn", dependencies: ["LockInCore"]),
        .testTarget(name: "LockInCoreTests", dependencies: ["LockInCore"]),
        .testTarget(name: "LockInAppTests", dependencies: ["LockIn", "LockInCore"])
    ],
    swiftLanguageModes: [.v5]
)
