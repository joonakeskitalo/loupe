// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Loupe",
            path: "Sources/Loupe"
        )
    ]
)
