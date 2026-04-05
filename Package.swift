// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macMCP",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "macmcp",
            path: "Sources/macMCP",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("Contacts"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/macMCP/Info.plist",
                ]),
            ]
        )
    ]
)
