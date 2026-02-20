// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macMCP",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "macmcp",
            path: "Sources/macMCP",
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("Contacts"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Foundation"),
            ]
        )
    ]
)
