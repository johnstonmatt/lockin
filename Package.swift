// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LockIn",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LockIn", targets: ["LockIn"]),
        // Not "lockin": it would collide with "LockIn" in the build directory on a case-insensitive disk.
        // The app bundle ships it as Contents/Helpers/lockin.
        .executable(name: "lockin-cli", targets: ["LockInCLI"])
    ],
    targets: [
        .target(name: "LockInCore"),
        .executableTarget(name: "LockIn", dependencies: ["LockInCore"]),
        .executableTarget(name: "LockInCLI", dependencies: ["LockInCore"]),
        .target(name: "LockInTestSupport", dependencies: ["LockInCore"], path: "Tests/LockInTestSupport"),
        .testTarget(name: "LockInCoreTests", dependencies: ["LockInCore", "LockInTestSupport"]),
        .testTarget(name: "LockInAppTests", dependencies: ["LockIn", "LockInCore", "LockInTestSupport"]),
        .testTarget(name: "LockInCLITests", dependencies: ["LockInCLI", "LockInCore", "LockInTestSupport"])
    ],
    swiftLanguageModes: [.v5]
)
