import Foundation

/// The transport surface a video backend must expose so the viewer's control
/// bar and keyboard shortcuts can drive it without caring which engine decodes
/// the frames.
///
/// Loupe has two backends: `VideoController` (AVFoundation) handles everything
/// the system can demux — mov/mp4/m4a and friends — while `MPVController`
/// (libmpv) handles the containers AVFoundation can't, notably Matroska
/// (`.mkv`) and WebM (`.webm`). Both publish the same observable state and the
/// same commands, so `MediaViewer` binds to either through this protocol.
///
/// Refines `ObservableObject` so SwiftUI redraws on state changes, and is
/// `@MainActor` because all playback state is touched from the main actor.
@MainActor
protocol PlaybackController: ObservableObject {
    /// Whether playback is currently running.
    var isPlaying: Bool { get }
    /// Current playback position in seconds.
    var currentTime: Double { get }
    /// Total duration in seconds (0 until known; reported asynchronously).
    var duration: Double { get }

    /// Toggle play/pause.
    func togglePlay()
    /// Begin playback.
    func play()
    /// Pause playback.
    func pause()

    /// Swap in a new file, resetting transport state.
    func load(url: URL)
    /// Stop playback and release observers/resources.
    func teardown()

    /// Seek to a fraction (0...1) of the total duration. No-op until the
    /// duration is known.
    func seek(toFraction fraction: Double)
    /// Skip forward (positive) or backward (negative) by a number of seconds.
    func skip(by seconds: Double)
    /// Step by a number of frames (negative = backward). Pauses first so the
    /// step is frame-accurate.
    func stepFrame(by count: Int)

    /// Called when the user starts dragging the scrubber.
    func beginScrubbing()
    /// Called continuously while the scrubber is dragged.
    func scrub(to seconds: Double)
    /// Called when the user releases the scrubber.
    func endScrubbing()
}
