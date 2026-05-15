// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PortalMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PortalMac", targets: ["PortalMac"])
    ],
    targets: [
        .executableTarget(
            name: "PortalMac",
            path: "Sources/PortalMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Network")
            ]
        )
    ]
)
