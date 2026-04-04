// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalLoom",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalLoom",
            dependencies: [
                .product(name: "Swifter", package: "swifter"),
            ],
            resources: [
                .copy("Resources/ngrok")
            ]
        ),
    ]
)
