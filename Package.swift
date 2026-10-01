// swift-tools-version:6.0
import PackageDescription

// Loupe links the official FFmpeg libraries (libavformat / libavcodec /
// libavutil / libswscale) to decode a frame from containers QuickLook and
// AVFoundation can't handle (.mkv / .webm). Headers and libraries are taken
// from the Homebrew `ffmpeg` formula at build time; the resulting dylibs are
// copied into the app bundle's Frameworks directory by build-app.sh.
//
// For *playback* of those same containers Loupe embeds libmpv (the Homebrew
// `mpv` formula), which is built on the same FFmpeg stack. Its headers/library
// are linked the same way and bundled by build-app.sh.
//
// Homebrew on Apple Silicon lives at /opt/homebrew. If you are on an Intel Mac
// (Homebrew at /usr/local) adjust the paths below.
let ffmpegPrefix = "/opt/homebrew/opt/ffmpeg"
let mpvPrefix = "/opt/homebrew/opt/mpv"

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
        .systemLibrary(
            name: "CMPV",
            path: "Sources/CMPV"
        ),
        .executableTarget(
            name: "Loupe",
            dependencies: ["CFFmpeg", "CMPV"],
            path: "Sources/Loupe",
            cSettings: [
                .unsafeFlags([
                    "-I\(ffmpegPrefix)/include",
                    "-I\(mpvPrefix)/include"
                ])
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-I\(ffmpegPrefix)/include",
                    "-I\(mpvPrefix)/include"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(ffmpegPrefix)/lib",
                    "-lavformat",
                    "-lavcodec",
                    "-lavutil",
                    "-lswscale",
                    "-L\(mpvPrefix)/lib",
                    "-lmpv"
                ])
            ]
        )
    ]
)
