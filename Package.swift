// swift-tools-version:6.0
import PackageDescription

// Loupe links the official FFmpeg libraries (libavformat / libavcodec /
// libavutil / libswscale) to decode a frame from containers QuickLook and
// AVFoundation can't handle (.mkv / .webm). Headers and libraries are taken
// from the Homebrew `ffmpeg` formula at build time; the resulting dylibs are
// copied into the app bundle's Frameworks directory by build-app.sh.
//
// Homebrew on Apple Silicon lives at /opt/homebrew. If you are on an Intel Mac
// (Homebrew at /usr/local) adjust the paths below.
let ffmpegPrefix = "/opt/homebrew/opt/ffmpeg"

let package = Package(
    name: "Loupe",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg"
        ),
        .executableTarget(
            name: "Loupe",
            dependencies: ["CFFmpeg"],
            path: "Sources/Loupe",
            cSettings: [
                .unsafeFlags(["-I\(ffmpegPrefix)/include"])
            ],
            swiftSettings: [
                .unsafeFlags(["-I\(ffmpegPrefix)/include"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(ffmpegPrefix)/lib",
                    "-lavformat",
                    "-lavcodec",
                    "-lavutil",
                    "-lswscale"
                ])
            ]
        )
    ]
)
