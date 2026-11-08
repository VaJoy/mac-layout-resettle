// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReSettle",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ReSettle",
            path: "Sources/ReSettle",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
