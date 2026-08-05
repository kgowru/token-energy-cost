// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentSpend",
    platforms: [.macOS(.v14)],
    targets: [
        // No external dependencies. SQLite comes from the system (`import SQLite3`),
        // which keeps the binary small and idle cost near zero — a menu bar tool
        // that burns CPU to report energy use would undercut its own premise.
        .executableTarget(
            name: "AgentSpend",
            path: "AgentSpend",
            exclude: ["Resources/README.md"],
            resources: [.copy("Resources/energy-model.json"),
                        .copy("Resources/pricing.json")]
        )
    ]
)
