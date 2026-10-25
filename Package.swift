// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DisplaySaver",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "DisplaySaver",
            path: "Sources/DisplaySaver",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
