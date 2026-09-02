// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentHub", targets: ["AgentHub"]),
        .executable(name: "agenthub-totp", targets: ["AgentHubTOTPCLI"]),
        .executable(name: "agenthub-task", targets: ["AgentHubTaskCLI"])
    ],
    targets: [
        .target(
            name: "AgentHubTOTPKit",
            path: "Sources/AgentHubTOTPKit",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("LocalAuthentication")]
        ),
        .executableTarget(
            name: "AgentHub",
            dependencies: ["AgentHubTOTPKit"],
            path: "Sources/QuotaBar",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("LocalAuthentication")]
        ),
        .executableTarget(
            name: "AgentHubTOTPCLI",
            dependencies: ["AgentHubTOTPKit"],
            path: "Sources/AgentHubTOTPCLI"
        ),
        .executableTarget(
            name: "AgentHubTaskCLI",
            path: "Sources/AgentHubTaskCLI"
        ),
        .testTarget(
            name: "AgentHubTests",
            dependencies: ["AgentHub", "AgentHubTOTPKit"],
            path: "Tests/QuotaBarTests"
        )
    ]
)
