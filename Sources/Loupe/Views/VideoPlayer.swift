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
    /// J over the video surface — move to the previous item. Handled in the
    /// player view so AVPlayerView's own J/L transport never intercepts it.
    var onPrevious: (() -> Void)? = nil
    /// L over the video surface — move to the next item.
    var onNext: (() -> Void)? = nil

    @StateObject private var controller: VideoController

    init(url: URL,
         onController: ((VideoController) -> Void)? = nil,
         onPrevious: (() -> Void)? = nil,
         onNext: (() -> Void)? = nil) {
        self.url = url
        self.onController = onController
        self.onPrevious = onPrevious
        self.onNext = onNext
        _controller = StateObject(wrappedValue: VideoController(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Video surface — AVPlayerView with its own controls disabled so
            // nothing is drawn over the frame. It also handles the spacebar.
            PlayerSurface(
                player: controller.player,
                onToggle: { controller.togglePlay() },
                onPrevious: onPrevious,
                onNext: onNext
            )
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
    /// Called when the user presses Space/K over the video surface.
    let onToggle: () -> Void
    /// Called on J — move to the previous item.
    var onPrevious: (() -> Void)? = nil
    /// Called on L — move to the next item.
    var onNext: (() -> Void)? = nil

    func makeNSView(context: Context) -> KeyablePlayerView {
        let view = KeyablePlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        view.onToggle = onToggle
        view.onPrevious = onPrevious
        view.onNext = onNext
        // Take first responder so the transport keys are handled here and never
        // bubble up to the window's hidden shortcut buttons.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: KeyablePlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.onToggle = onToggle
        nsView.onPrevious = onPrevious
        nsView.onNext = onNext
    }
}

/// AVPlayerView subclass used purely as the video surface.
///
/// AVKit's player view (even with `controlsStyle = .none`) installs its own
/// first-responder machinery that claims the J/K/L and arrow transport keys and
/// changes playback speed. Overriding `keyDown`/`performKeyEquivalent` on this
/// subclass isn't reliable because AVKit routes those keys to a private
/// internal responder, not to us.
///
/// To guarantee our shortcuts win, we install a window-scoped local key-down
/// event monitor while the view is in a window. The monitor sees every key
/// event BEFORE it reaches AVKit's responder, so it can run our action and
/// swallow the event (return nil) for the keys we own, and pass everything else
/// through untouched for the SwiftUI shortcuts.
final class KeyablePlayerView: AVPlayerView {
    var onToggle: (() -> Void)?
    /// J — go to the previous item (not AVPlayerView's rewind/slow-mo).
    var onPrevious: (() -> Void)?
    /// L — go to the next item (not AVPlayerView's fast-forward/speed-up).
    var onNext: (() -> Void)?

    private var keyMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only act while this view is actually in the key window and on
            // screen, so a background player window doesn't eat another's keys.
            guard let window = self.window, window.isKeyWindow else { return event }

            // Ignore modified combos so ⌘-based shortcuts still work.
            let modified = !event.modifierFlags
                .intersection([.command, .control, .option])
                .isEmpty
            if modified { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k", " ":
                self.onToggle?()
                return nil          // swallow
            case "j":
                self.onPrevious?()
                return nil
            case "l":
                self.onNext?()
                return nil
            default:
                return event        // let everything else through
            }
        }
    }

    private func removeMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
