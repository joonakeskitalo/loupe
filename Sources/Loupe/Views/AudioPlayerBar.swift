import SwiftUI
import AVFoundation

/// Drives a lightweight AVPlayer for the bottom audio bar.
@MainActor
final class AudioBarController: ObservableObject {
    private let player = AVPlayer()

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 1 {
        didSet { player.volume = Float(volume) }
    }
    @Published var loadedURL: URL?

    /// Called when the current track plays to its end.
    var onFinished: (() -> Void)?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isScrubbing = false

    init() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isScrubbing { self.currentTime = time.seconds }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                }
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    /// Loads `url`. Keeps playing if something was already playing.
    func load(url: URL) {
        guard url != loadedURL else { return }
        let wasPlaying = isPlaying
        loadedURL = url
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = 0
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.seek(to: .zero)
                self.isPlaying = false
                self.onFinished?()
            }
        }
        if wasPlaying { play() } else { isPlaying = false }
    }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func togglePlay() { player.rate == 0 ? play() : pause() }

    func skip(by seconds: Double) {
        let target = min(max(currentTime + seconds, 0), duration > 0 ? duration : .greatestFiniteMagnitude)
        seek(to: target)
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func setScrubbing(_ scrubbing: Bool) { isScrubbing = scrubbing }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        loadedURL = nil
        currentTime = 0
        duration = 0
    }

    deinit {
        MainActor.assumeIsolated {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        }
    }
}

/// An audio player bar docked at the bottom of the browser (grid or list). It
/// plays the selected audio item; selecting another audio item switches the
/// track, continuing playback if it was running.
struct AudioPlayerBar: View {
    var model: BrowserModel
    @StateObject private var controller = AudioBarController()
    @State private var scrubValue: Double = 0
    @State private var isDragging = false

    private var audioItems: [MediaItem] {
        model.displayedItems.filter { $0.kind == .audio }
    }

    private var currentIndex: Int? {
        guard let url = controller.loadedURL else { return nil }
        return audioItems.firstIndex { $0.url == url }
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button { step(-1) } label: { Image(systemName: "backward.end.fill") }
                    .disabled(!canStep(-1))
                    .help("Previous audio file")
                Button { controller.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                    .disabled(controller.loadedURL == nil)
                    .help("Back 15 seconds")
                Button { controller.togglePlay() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .disabled(controller.loadedURL == nil)
                .help(controller.isPlaying ? "Pause" : "Play")
                Button { controller.skip(by: 15) } label: { Image(systemName: "goforward.15") }
                    .disabled(controller.loadedURL == nil)
                    .help("Forward 15 seconds")
                Button { step(1) } label: { Image(systemName: "forward.end.fill") }
                    .disabled(!canStep(1))
                    .help("Next audio file")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.loadedURL?.lastPathComponent ?? "Select an audio file")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(controller.loadedURL == nil ? .secondary : .primary)
                HStack(spacing: 8) {
                    Text(format(isDragging ? scrubValue : controller.currentTime))
                    Slider(
                        value: Binding(
                            get: { isDragging ? scrubValue : controller.currentTime },
                            set: { scrubValue = $0 }
                        ),
                        in: 0...max(controller.duration, 0.01),
                        onEditingChanged: { editing in
                            if editing {
                                scrubValue = controller.currentTime
                                controller.setScrubbing(true)
                                isDragging = true
                            } else {
                                controller.seek(to: scrubValue)
                                controller.setScrubbing(false)
                                isDragging = false
                            }
                        }
                    )
                    .controlSize(.small)
                    .disabled(controller.loadedURL == nil || controller.duration <= 0)
                    Text(format(controller.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: controller.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Slider(value: $controller.volume, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 90)
            }

            Button {
                controller.stop()
                model.showAudioPlayer = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close audio player")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onAppear {
            controller.onFinished = { advanceAfterFinish() }
            loadSelectionIfAudio()
        }
        .onDisappear { controller.stop() }
        .onChange(of: model.selectedItem) { _, _ in loadSelectionIfAudio() }
    }

    private func loadSelectionIfAudio() {
        if let item = model.primarySelectedItem, item.kind == .audio {
            controller.load(url: item.url)
        }
    }

    private func canStep(_ delta: Int) -> Bool {
        guard let i = currentIndex else { return !audioItems.isEmpty }
        return audioItems.indices.contains(i + delta)
    }

    /// Moves to the previous/next audio item and selects it in the browser.
    private func step(_ delta: Int) {
        let items = audioItems
        guard !items.isEmpty else { return }
        let target = currentIndex.map { $0 + delta } ?? 0
        guard items.indices.contains(target) else { return }
        select(items[target])
    }

    private func select(_ item: MediaItem) {
        model.selectedItem = item.id
        model.selectedItems = [item.id]
        controller.load(url: item.url)
    }

    /// Auto-advance to the next audio file when a track ends.
    private func advanceAfterFinish() {
        guard let i = currentIndex, audioItems.indices.contains(i + 1) else { return }
        controller.play()
        select(audioItems[i + 1])
        controller.play()
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
