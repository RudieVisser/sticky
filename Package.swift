// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sticky",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Sticky",
            path: "Sources/Sticky"
        )
    ]
)
