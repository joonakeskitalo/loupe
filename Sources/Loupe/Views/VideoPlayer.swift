import SwiftUI
import AVKit
import Combine

/// Drives an AVPlayer and publishes just enough state for a custom control bar
/// that sits BELOW the video, so the controls never overlap the picture.
@MainActor
final class VideoController: ObservableObject, PlaybackController {
    let player: AVPlayer

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var endObserver: NSObjectProtocol?

    /// True while the user is dragging the scrubber. During a scrub the
    /// periodic time observer must not write `currentTime` back from the
    /// player's (lagging) position, otherwise the thumb fights the drag and
    /// stutters.
    private var isScrubbing = false
    /// Guards against overlapping seeks: a new scrub target is only dispatched
    /// once the previous seek completes, with the latest requested time applied
    /// at the end. This keeps fast dragging smooth instead of queuing seeks.
    private var isSeekInFlight = false
    private var pendingSeekTime: Double?
    /// Whether playback was running when scrubbing began, so we can resume it.
    private var wasPlayingBeforeScrub = false

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
                // While scrubbing OR while a keyboard-driven jump seek is still
                // in flight, our target owns `currentTime`; don't let the
                // player's lagging position overwrite it and snap the thumb
                // backward (which looks like a stutter).
                if !self.isScrubbing && !self.isSeekInFlight {
                    self.currentTime = time.seconds
                }
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

    /// Call when the user starts dragging the scrubber. Pauses playback (so
    /// audio doesn't chirp during the drag) and takes over `currentTime` so the
    /// thumb tracks the finger precisely.
    func beginScrubbing() {
        isScrubbing = true
        wasPlayingBeforeScrub = player.rate != 0
        if wasPlayingBeforeScrub { player.pause() }
    }

    /// Called continuously as the scrubber is dragged. Updates the thumb
    /// position immediately and issues a fast, tolerant seek. Overlapping seeks
    /// are coalesced: only one runs at a time and the most recent target is
    /// applied when it finishes, so rapid dragging stays smooth.
    func scrub(to seconds: Double) {
        currentTime = seconds
        pendingSeekTime = seconds
        dispatchPendingSeek()
    }

    /// Call when the user releases the scrubber. Does a final precise seek to
    /// the drop point and resumes playback if it was playing before.
    func endScrubbing() {
        isScrubbing = false
        let target = pendingSeekTime ?? currentTime
        pendingSeekTime = nil
        // Precise final seek so the frame matches exactly where the user let go.
        // Seek completion handlers fire on an arbitrary queue, so hop to the
        // main actor before touching player/published state.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.wasPlayingBeforeScrub { self.play() }
            }
        }
    }

    /// Issues the next tolerant seek if one isn't already running. Tolerant
    /// seeks (non-zero tolerance) are far cheaper than exact seeks, which is
    /// what makes continuous scrubbing responsive.
    private func dispatchPendingSeek() {
        guard !isSeekInFlight, let target = pendingSeekTime else { return }
        pendingSeekTime = nil
        isSeekInFlight = true
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            // Completion fires on an arbitrary queue; hop to the main actor.
            Task { @MainActor in
                guard let self else { return }
                self.isSeekInFlight = false
                // If more drag arrived while this seek ran, chase the latest.
                self.dispatchPendingSeek()
            }
        }
    }

    /// A discrete, keyboard-driven jump (percentage keys, U/O skips). Moves the
    /// thumb immediately, then uses the same coalesced, tolerant seek as the
    /// scrubber so rapid presses stay smooth instead of queuing slow exact
    /// seeks (which caused the thumb to stutter).
    func jump(to seconds: Double) {
        let target: Double
        if duration.isFinite, duration > 0 {
            target = min(max(seconds, 0), duration)
        } else {
            target = max(seconds, 0)
        }
        currentTime = target
        pendingSeekTime = target
        dispatchPendingSeek()
    }

    /// Seeks to a fraction (0...1) of the total duration. Used by the number-key
    /// hotkeys that jump to 0%, 10%, … of the video. No-op until the duration is
    /// known (it's reported asynchronously once the item is ready).
    func seek(toFraction fraction: Double) {
        guard duration.isFinite, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        jump(to: duration * clamped)
    }

    /// Skips forward (positive) or backward (negative) by a number of seconds,
    /// clamped to the valid range. Used by the U/O 15-second skip hotkeys.
    func skip(by seconds: Double) {
        jump(to: currentTime + seconds)
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

/// Picks the playback backend for a video/audio item. AVFoundation handles
/// everything the system can demux; libmpv (via `MPVVideoPlayerView`) handles
/// the containers it can't — Matroska `.mkv` and WebM `.webm`. Both render the
/// same control bar beneath the picture and expose the same
/// `PlaybackController` to the parent viewer, so the keyboard shortcuts work
/// identically regardless of which engine is decoding.
struct VideoPlayerView: View {
    let url: URL
    /// Lets the parent reach the controller (e.g. for the spacebar shortcut).
    var onController: ((any PlaybackController) -> Void)? = nil
    /// J over the video surface — move to the previous item.
    var onPrevious: (() -> Void)? = nil
    /// L over the video surface — move to the next item.
    var onNext: (() -> Void)? = nil
    /// ←/→ over the video surface — navigate between items (forward == Right),
    /// with `shift` indicating a Shift+arrow (extend) press. Routed through the
    /// surface's key monitor so navigation keeps working even once the video
    /// view holds first responder and SwiftUI's `.onKeyPress` stops firing.
    var onArrow: ((_ forward: Bool, _ shift: Bool) -> Void)? = nil
    /// Whether this player owns the keyboard transport keys (Space/K/J/L and,
    /// in the viewer, the ←/→ navigation arrows).
    /// Only the fullscreen viewer sets this: it's the surface the user drives
    /// with the keyboard, so it should capture those keys. An inline preview
    /// (the sidebar, a grid tile) leaves it `false` so it never installs a key
    /// monitor and the browser's own hotkeys (Space to open, J/L to navigate,
    /// flag/tag keys) keep working while a video happens to be showing.
    var capturesKeyboard: Bool = false

    /// True when the extension is one AVFoundation can't demux and mpv must
    /// handle. Reuses the single source of truth in `MediaItem`.
    private var needsMPV: Bool {
        MediaKind.videoExtensions.contains(url.pathExtension.lowercased())
    }

    var body: some View {
        // `.id(needsMPV)` so switching between an AV item and an mpv item
        // rebuilds the correct backing view instead of reusing the wrong one.
        Group {
            if needsMPV {
                MPVVideoPlayerView(url: url, onController: onController,
                                   onPrevious: onPrevious, onNext: onNext,
                                   onArrow: onArrow,
                                   capturesKeyboard: capturesKeyboard)
            } else {
                AVVideoPlayerView(url: url, onController: onController,
                                  onPrevious: onPrevious, onNext: onNext,
                                  onArrow: onArrow,
                                  capturesKeyboard: capturesKeyboard)
            }
        }
        .id(needsMPV)
    }
}

/// AVFoundation-backed player: the original Loupe video view. Transport
/// controls live in a bar beneath the video so they never cover the picture.
struct AVVideoPlayerView: View {
    let url: URL
    var onController: ((any PlaybackController) -> Void)? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var onArrow: ((_ forward: Bool, _ shift: Bool) -> Void)? = nil
    var capturesKeyboard: Bool = false

    @StateObject private var controller: VideoController

    init(url: URL,
         onController: ((any PlaybackController) -> Void)? = nil,
         onPrevious: (() -> Void)? = nil,
         onNext: (() -> Void)? = nil,
         onArrow: ((_ forward: Bool, _ shift: Bool) -> Void)? = nil,
         capturesKeyboard: Bool = false) {
        self.url = url
        self.onController = onController
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onArrow = onArrow
        self.capturesKeyboard = capturesKeyboard
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
                onNext: onNext,
                onArrow: onArrow,
                capturesKeyboard: capturesKeyboard
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PlaybackControlBar(controller: controller)
        }
        .onAppear { onController?(controller) }
        .onDisappear { controller.teardown() }
        .onChange(of: url) { _, newURL in
            controller.load(url: newURL)
            onController?(controller)
        }
    }
}

/// libmpv-backed player for `.mkv` / `.webm`. Mirrors `AVVideoPlayerView`'s
/// layout: the mpv GL surface fills the space with the shared control bar
/// beneath it.
struct MPVVideoPlayerView: View {
    let url: URL
    var onController: ((any PlaybackController) -> Void)? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    var onArrow: ((_ forward: Bool, _ shift: Bool) -> Void)? = nil
    var capturesKeyboard: Bool = false

    @StateObject private var controller: MPVController

    init(url: URL,
         onController: ((any PlaybackController) -> Void)? = nil,
         onPrevious: (() -> Void)? = nil,
         onNext: (() -> Void)? = nil,
         onArrow: ((_ forward: Bool, _ shift: Bool) -> Void)? = nil,
         capturesKeyboard: Bool = false) {
        self.url = url
        self.onController = onController
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onArrow = onArrow
        self.capturesKeyboard = capturesKeyboard
        _controller = StateObject(wrappedValue: MPVController(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            MPVSurface(controller: controller, onPrevious: onPrevious, onNext: onNext,
                       onArrow: onArrow, capturesKeyboard: capturesKeyboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            PlaybackControlBar(controller: controller)
        }
        .onAppear {
            controller.start()
            onController?(controller)
        }
        .onDisappear { controller.teardown() }
        .onChange(of: url) { _, newURL in
            controller.load(url: newURL)
            onController?(controller)
        }
    }
}

/// The transport bar shown beneath the video for either backend. Generic over
/// the concrete `PlaybackController` so SwiftUI observes the right
/// `ObservableObject` and redraws as its published state changes.
struct PlaybackControlBar<C: PlaybackController>: View {
    @ObservedObject var controller: C

    var body: some View {
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
                    set: { controller.scrub(to: $0) }
                ),
                in: 0...max(controller.duration, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        controller.beginScrubbing()
                    } else {
                        controller.endScrubbing()
                    }
                }
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
    /// Called on ←/→ (forward == Right); `shift` marks a Shift+arrow press.
    var onArrow: ((_ forward: Bool, _ shift: Bool) -> Void)? = nil
    /// Whether to install the window-level transport-key monitor. Only the
    /// fullscreen viewer sets this; inline previews leave it off so they never
    /// claim the browser's hotkeys.
    var capturesKeyboard: Bool = false

    func makeNSView(context: Context) -> KeyablePlayerView {
        let view = KeyablePlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        view.onToggle = onToggle
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onArrow = onArrow
        view.capturesKeyboard = capturesKeyboard
        // Intentionally do NOT make this the first responder. AVKit's
        // AVPlayerView installs its own key handling (transport keys, arrows,
        // speed changes) the moment it becomes first responder, which overrode
        // the app's hotkeys. Keeping it out of the responder chain means AVKit
        // never receives key events, so every app hotkey reaches its normal
        // handler. The player's OWN keys are driven by the window-level key
        // monitor below, which works regardless of first-responder status.
        return view
    }

    func updateNSView(_ nsView: KeyablePlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.onToggle = onToggle
        nsView.onPrevious = onPrevious
        nsView.onNext = onNext
        nsView.onArrow = onArrow
        nsView.capturesKeyboard = capturesKeyboard
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
    /// ←/→ — navigate between items (forward == Right); `shift` marks a
    /// Shift+arrow (extend) press. Handled here, by the monitor, rather than
    /// via SwiftUI's `.onKeyPress` because once a video plays this view can take
    /// first responder and SwiftUI focus leaves the viewer, so `.onKeyPress`
    /// stops firing — but this window-level monitor keeps receiving keys.
    var onArrow: ((_ forward: Bool, _ shift: Bool) -> Void)?
    /// Whether this surface owns the transport keys. When false (inline
    /// previews) no monitor is installed, so the browser's own hotkeys keep
    /// working while a video is merely showing. Toggling it adds/removes the
    /// monitor so a view reused across contexts behaves correctly.
    var capturesKeyboard: Bool = false {
        didSet {
            guard capturesKeyboard != oldValue else { return }
            refreshMonitor()
        }
    }

    private var keyMonitor: Any?

    // Decline first responder so AVKit's AVPlayerView never installs its own
    // key handling (which claims arrows/space/J/K/L and speed keys and overrode
    // the app's hotkeys). The player's own keys are driven by the window-level
    // `keyMonitor` instead, which doesn't need first-responder status. A click
    // on the video still toggles play/pause via that monitor's Space/K path.
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshMonitor()
    }

    /// Install the monitor only when in a window AND this surface owns the
    /// keyboard; otherwise tear it down.
    private func refreshMonitor() {
        if window != nil && capturesKeyboard {
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

            // Yield entirely while the tag-input overlay is focused, so J/L/K/
            // Space type into the tag field instead of driving the video.
            if MainActor.assumeIsolated({ TagInputState.isActive }) { return event }

            // Ignore modified combos so ⌘-based shortcuts still work.
            let modified = !event.modifierFlags
                .intersection([.command, .control, .option])
                .isEmpty
            if modified { return event }

            // ←/→ item navigation. Driven here (not via SwiftUI `.onKeyPress`)
            // so it survives the video view holding first responder. Shift is
            // read off the event so the viewer's extend-selection still works.
            if let onArrow = self.onArrow {
                switch event.keyCode {
                case 123:   // Left arrow
                    onArrow(false, event.modifierFlags.contains(.shift))
                    return nil
                case 124:   // Right arrow
                    onArrow(true, event.modifierFlags.contains(.shift))
                    return nil
                default:
                    break
                }
            }

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
