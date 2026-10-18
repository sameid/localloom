// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalLoom",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LocalLoom",
            resources: [
                .copy("Resources/ngrok")
            ]
        ),
        .testTarget(
            name: "LocalLoomTests",
            dependencies: ["LocalLoom"]
        ),
    ]
)
