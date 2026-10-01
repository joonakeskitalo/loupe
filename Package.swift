// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Loupe",
            path: "Sources/Loupe"
        )
    ]
)
