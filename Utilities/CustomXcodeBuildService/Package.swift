// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CustomXcodeBuildService",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "custom-xcode-build-service", targets: ["CustomXcodeBuildService"])],
    targets: [
        .executableTarget(name: "CustomXcodeBuildService"),
        .testTarget(name: "CustomXcodeBuildServiceTests", dependencies: ["CustomXcodeBuildService"]),
    ]
)
