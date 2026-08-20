// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AgentHub", targets: ["AgentHub"])],
    targets: [
        .executableTarget(
            name: "AgentHub",
            path: "Sources/QuotaBar"
        ),
        .testTarget(
            name: "AgentHubTests",
            dependencies: ["AgentHub"],
            path: "Tests/QuotaBarTests"
        )
    ]
)
