import SwiftUI
import AVKit
import Combine

/// Drives an AVPlayer and publishes just enough state for a custom control bar
/// that sits BELOW the video, so the controls never overlap the picture.
@MainActor
final class VideoController: ObservableObject {
    let player: AVPlayer

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        player = AVPlayer(url: url)
        observe()
        play()
    }

    func load(url: URL) {
        teardown()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = 0
        observe()
        play()
    }

    private func observe() {
        // Periodic time updates for the scrubber.
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // Delivered on the main queue, so it is safe to hop to the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                }
                self.isPlaying = self.player.rate != 0
            }
        }

        // Reset to start when playback finishes.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.seek(to: .zero)
                self.isPlaying = false
            }
        }
    }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }

    func togglePlay() {
        if player.rate == 0 { play() } else { pause() }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    /// Seeks to a fraction (0...1) of the total duration. Used by the number-key
    /// hotkeys that jump to 0%, 10%, … of the video. No-op until the duration is
    /// known (it's reported asynchronously once the item is ready).
    func seek(toFraction fraction: Double) {
        guard duration.isFinite, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        seek(to: duration * clamped)
    }

    /// Skips forward (positive) or backward (negative) by a number of seconds,
    /// clamped to the valid range. Used by the U/O 15-second skip hotkeys.
    func skip(by seconds: Double) {
        let target: Double
        if duration.isFinite, duration > 0 {
            target = min(max(currentTime + seconds, 0), duration)
        } else {
            target = max(currentTime + seconds, 0)
        }
        seek(to: target)
    }

    /// Steps the video by a number of frames (negative = backward). Pauses
    /// playback first so stepping is frame-accurate, then uses AVFoundation's
    /// native frame stepping when the item reports it can step that direction.
    func stepFrame(by count: Int) {
        guard count != 0, let item = player.currentItem else { return }
        pause()
        let canStep = count > 0 ? item.canStepForward : item.canStepBackward
        if canStep {
            item.step(byCount: count)
            currentTime = player.currentTime().seconds
        }
    }

    /// Stops playback and removes observers. Call when the view disappears.
    func teardown() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

/// A video player whose transport controls live in a bar beneath the video,
/// so they never cover the picture. Space toggles play/pause (handled by the
/// parent viewer, which calls `controller.togglePlay()`).
struct VideoPlayerView: View {
    let url: URL
    /// Lets the parent reach the controller (e.g. for the spacebar shortcut).
    var onController: ((VideoController) -> Void)? = nil

    @StateObject private var controller: VideoController

    init(url: URL, onController: ((VideoController) -> Void)? = nil) {
        self.url = url
        self.onController = onController
        _controller = StateObject(wrappedValue: VideoController(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Video surface — AVPlayerView with its own controls disabled so
            // nothing is drawn over the frame. It also handles the spacebar.
            PlayerSurface(player: controller.player) {
                controller.togglePlay()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlBar
        }
        .onAppear { onController?(controller) }
        .onDisappear { controller.teardown() }
        .onChange(of: url) { _, newURL in
            controller.load(url: newURL)
            onController?(controller)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                controller.togglePlay()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 28)
            }
            .buttonStyle(.plain)
            .help(controller.isPlaying ? "Pause (Space)" : "Play (Space)")

            Text(timeString(controller.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 46, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.seek(to: $0) }
                ),
                in: 0...max(controller.duration, 0.1)
            )
            .controlSize(.small)

            Text(timeString(controller.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 46, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.1))
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Bare AVPlayerView with no built-in controls, used purely as the video
/// surface so our own control bar below it is the only chrome.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    /// Called when the user presses Space over the video surface.
    let onToggle: () -> Void

    func makeNSView(context: Context) -> KeyablePlayerView {
        let view = KeyablePlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        view.onToggle = onToggle
        // Take first responder so the Space key is handled here and never
        // bubbles up to the window's hidden shortcut buttons.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: KeyablePlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.onToggle = onToggle
    }
}

/// AVPlayerView subclass that intercepts the spacebar to toggle play/pause and
/// consumes the event, so Space never reaches the window-level shortcuts that
/// would otherwise close the viewer.
final class KeyablePlayerView: AVPlayerView {
    var onToggle: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 49 is the spacebar key code — toggle play/pause and consume it.
        if event.keyCode == 49 {
            onToggle?()
            return
        }
        // Let other keys (arrows for item navigation, Esc to close) bubble up
        // the responder chain to the SwiftUI shortcuts rather than being
        // swallowed by AVPlayerView's own key handling.
        nextResponder?.keyDown(with: event)
    }
}
