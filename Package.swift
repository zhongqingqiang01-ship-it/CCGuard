// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CCGuard", platforms: [.macOS(.v14)],
    products: [.executable(name: "CCGuard", targets: ["CCGuardApp"])],
    targets: [
        .target(name: "CCGuardCore"),
        .executableTarget(name: "CCGuardApp", dependencies: ["CCGuardCore"]),
        .testTarget(name: "CCGuardCoreTests", dependencies: ["CCGuardCore"])
    ], swiftLanguageModes: [.v5])
