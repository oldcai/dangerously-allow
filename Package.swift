// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dangerously-allow",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "dangerously-allow", targets: ["DangerouslyAllow"]),
        .library(name: "DangerouslyAllowCore", targets: ["DangerouslyAllowCore"]),
    ],
    targets: [
        .target(name: "DangerouslyAllowCore"),
        .executableTarget(
            name: "DangerouslyAllow",
            dependencies: ["DangerouslyAllowCore"]
        ),
        .testTarget(
            name: "DangerouslyAllowCoreTests",
            dependencies: ["DangerouslyAllowCore"]
        ),
    ]
)
