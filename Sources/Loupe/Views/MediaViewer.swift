import SwiftUI
import AVKit
import PDFKit
import QuickLookUI

/// Full-item viewer presented over the grid. Supports image zoom/pan, video
/// playback, PDF scrolling, and a QuickLook fallback for everything else.
/// Arrow keys move between items; Escape / the close button dismisses.
struct MediaViewer: View {
    @Bindable var model: BrowserModel

    /// Pending zoom command and live zoom factor for the single-image viewer.
    @State private var zoomCommand: ZoomCommand?
    @State private var zoomFactor: CGFloat = 1

    /// The active video controller (when a single video/audio item is shown),
    /// so the spacebar can toggle playback. Either backend (AVFoundation or
    /// libmpv) is driven through the `PlaybackController` protocol.
    @State private var videoController: (any PlaybackController)?

    /// Drives keyboard focus for the viewer. Set true on appear so arrow-key
    /// navigation and the other `onKeyPress` hotkeys work immediately after the
    /// viewer opens (e.g. from a double-click on a grid item), without the user
    /// first having to click the image or a film-strip thumbnail.
    @FocusState private var isFocused: Bool

    private var showingSingleVideo: Bool {
        !isMulti && (items.first?.kind == .video || items.first?.kind == .audio)
    }

    /// The items to show: all selected items, falling back to the primary one.
    private var items: [MediaItem] {
        let selected = model.selectedMediaItems
        if selected.isEmpty, let one = model.selectedMediaItem { return [one] }
        return selected
    }

    private var isMulti: Bool { items.count > 1 }

    /// True when the single-item view is showing a zoomable image.
    private var showingSingleImage: Bool {
        !isMulti && items.first?.kind == .image
    }

    /// Whether the film strip is applicable: there's more than one item to
    /// navigate/select between. Shown in both the single-item and multi-grid
    /// views so a multi-selection can be built up straight from the strip.
    private var canShowFilmStrip: Bool {
        model.displayedItems.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top chrome bar (close button) — separated from the media so it
            // never overlaps content.
            toolbar

            // Media area.
            ZStack {
                Color.black
                if items.isEmpty {
                    Text("No selection").foregroundStyle(.secondary)
                } else if isMulti {
                    MultiGrid(model: model, items: items)
                } else {
                    // No `.id(...)` here: reusing the same underlying view across
                    // navigation lets the image swap + refit happen in one pass,
                    // avoiding the flash of recreating the NSView from scratch.
                    content(for: items[0])
                        .overlay(alignment: .leading) { navButton(symbol: "chevron.left", offset: -1) }
                        .overlay(alignment: .trailing) { navButton(symbol: "chevron.right", offset: 1) }
                        // Always start a freshly-opened image fitted — never
                        // inherit a previous zoom level.
                        .onAppear { zoomCommand = .fit }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if showingSingleImage { zoomHotkeys } }
            // Bare "T" toggles the film strip whenever it's applicable.
            .background {
                if canShowFilmStrip {
                    hotkey("t", []) {
                        withAnimation(.easeInOut(duration: 0.2)) { model.toggleFilmStrip() }
                    }
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
            }
            // Number keys jump to a percentage of the video: 1→10%, 2→20%, …,
            // 9→90%, and 0→start. Only active for a single video/audio item.
            .background {
                if showingSingleVideo {
                    percentageSeekHotkeys
                }
            }
            // J/L move between items, K exits the viewer, I flags the current
            // item. U/O skip the video back/forward 15s (single video/audio).
            .background { navigationHotkeys }
            // Trackpad swipes / horizontal scroll step between items. Sits
            // behind the media so it only catches gestures the content itself
            // doesn't consume (e.g. video, PDF, QuickLook). Images route their
            // own swipe through ZoomableImageView while fitted.
            .background {
                if !isMulti {
                    SwipeNavigator(
                        onPrevious: { model.moveSelection(by: -1) },
                        onNext: { model.moveSelection(by: 1) }
                    )
                }
            }

            // Film strip of thumbnails for quick navigation between items.
            // Only shown for the single-item view when there's more than one
            // item to move between, and when the user hasn't hidden it.
            if canShowFilmStrip && model.isFilmStripVisible {
                FilmStrip(
                    model: model,
                    // Use the visual (grouped) order, not the flat sort: the
                    // viewer's Next/Prev step through `visualOrderItems`, so the
                    // strip must show that same sequence or the highlight jumps
                    // around instead of walking to the adjacent thumbnail. With
                    // grouping off the two orders are identical.
                    items: model.visualOrderItems,
                    selectedIDs: model.selectedItems,
                    currentID: model.selectedItem
                )
            }

            // Caption bar below the media — the filename lives here so it can
            // never cover the image.
            captionBar
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        // ⌘⌫ trashes the shown item(s). The viewer carries its own copy of this
        // shortcut (like its other hotkeys) rather than relying on the menu-bar
        // command: while the viewer is open it owns focus, and the menu command
        // yields (ContentView stops publishing its model), so exactly one ⌘⌫
        // owner is live at a time.
        .background { trashHotkey }
        .background { copyHotkey }
        // Space + arrow keys are handled through one modifier (see
        // `ViewerKeyHandling`) so the main view's modifier chain stays small
        // enough for the type-checker. Arrows go through `onKeyPress` rather
        // than `keyboardShortcut` so plain and Shift variants disambiguate
        // reliably: SwiftUI's arrow-key shortcut matching ignores the Shift
        // modifier, which made a plain ←/→ trigger the Shift (extend) action.
        .modifier(ViewerKeyHandling(
            onSpace: {
                if showingSingleVideo, let videoController {
                    videoController.togglePlay()
                }
            },
            onArrow: { forward, shift in handleArrow(forward: forward, shift: shift) }
        ))
        .onChange(of: items.first?.id) { _, _ in
            if !showingSingleVideo { videoController = nil }
            prefetchUpcomingImages()
        }
        .onChange(of: items.count) { _, _ in prefetchUpcomingImages() }
        .onAppear {
            prefetchUpcomingImages()
            // Grab keyboard focus so arrow-key navigation works right away,
            // even before the user clicks inside the viewer. Deferred to the
            // next runloop tick so the focusable view is installed first.
            DispatchQueue.main.async { isFocused = true }
        }
    }

    /// Routes a Left/Right arrow press. Shift grows/shrinks the selection one
    /// item at a time; without Shift it pages the whole set by its size
    /// (single-step when one item is shown).
    private func handleArrow(forward: Bool, shift: Bool) -> KeyPress.Result {
        let direction = forward ? 1 : -1
        if shift {
            model.extendViewerSelection(by: direction)
        } else {
            model.moveSelectionBlock(by: direction)
        }
        return .handled
    }

    /// Warm the preloader with the images the next arrow press will reveal so
    /// forward browsing swaps instantly instead of decoding on the fly.
    ///
    /// For a single image that's the next two files; for a side-by-side
    /// multi-selection of N images it's the next N files (one full block ahead,
    /// matching how the arrow keys page). Only runs when the current view is
    /// made of images, since only images use the preloader.
    private func prefetchUpcomingImages() {
        guard !items.isEmpty, items.allSatisfy({ $0.kind == .image }) else { return }
        let count = max(2, items.count)
        let urls = model.upcomingImageURLs(count: count)
        guard !urls.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            await ImagePreloader.shared.prefetch(urls)
        }
    }

    /// Number of currently shown items that are flagged.
    private var flaggedShownCount: Int {
        items.filter { model.isFlagged($0.id) }.count
    }

    /// Number of currently shown items carrying any color tag.
    private var taggedShownCount: Int {
        items.filter { model.colorTag($0.id) != nil }.count
    }

    /// The most common color tag among the shown items, used to color the
    /// multi-item "N tagged" chip. Falls back to red if (somehow) empty.
    private var dominantShownTag: ColorTag {
        let tags = items.compactMap { model.colorTag($0.id) }
        let counts = Dictionary(grouping: tags, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? .red
    }

    /// Total on-disk size of all currently shown items, for the multi-item
    /// caption's combined size readout.
    private var combinedSize: Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }

    @ViewBuilder
    private var captionBar: some View {
        HStack {
            if isMulti {
                Text("\(items.count) items selected")
                if flaggedShownCount > 0 {
                    flagChip(text: "\(flaggedShownCount) flagged")
                }
                if taggedShownCount > 0 {
                    colorTagChip(tag: dominantShownTag, text: "\(taggedShownCount) tagged")
                }
                Spacer(minLength: 8)
                Text(formattedSize(combinedSize))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            } else if let item = items.first {
                Image(systemName: item.kind.fallbackSymbol)
                    .layoutPriority(1)
                Text(item.url.path)
                    .help(item.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.isFlagged(item.id) {
                    flagChip(text: "Flagged").layoutPriority(1)
                }
                if let tag = model.colorTag(item.id) {
                    colorTagChip(tag: tag, text: tag.displayName).layoutPriority(1)
                }
                Text(formattedSize(item.fileSize))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            } else {
                Spacer()
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.6))
        .lineLimit(1)
        .truncationMode(.middle)
        // Fix the content row height so the bar stays the same height whether
        // or not the flag chip is shown (the chip is slightly taller than the
        // plain caption text).
        .frame(height: captionContentHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
    }

    /// Fixed height for the caption bar's content row.
    private let captionContentHeight: CGFloat = 20

    /// A human-readable file size (e.g. "4.2 MB") using the system's file
    /// byte-count formatting, matching the grid's PathBar.
    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// A small orange flag pill shown in the caption bar when the viewed
    /// item(s) are flagged, matching the grid's orange flag styling.
    private func flagChip(text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.fill")
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.orange, in: Capsule())
    }

    /// A color-tag pill shown in the caption bar, mirroring `flagChip` but
    /// filled with the tag's own color.
    private func colorTagChip(tag: ColorTag, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: tag.symbol)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tag.color, in: Capsule())
    }

    @ViewBuilder
    private func content(for item: MediaItem) -> some View {
        switch item.kind {
        case .image:
            ZoomableImageView(
                url: item.url,
                command: $zoomCommand,
                zoomFactor: $zoomFactor,
                onSwipePrevious: { model.moveSelection(by: -1) },
                onSwipeNext: { model.moveSelection(by: 1) }
            )
        case .video, .audio:
            VideoPlayerView(
                url: item.url,
                onController: { controller in videoController = controller },
                onPrevious: { model.moveSelection(by: -1) },
                onNext: { model.moveSelection(by: 1) }
            )
        case .pdf:
            PDFViewerRepresentable(url: item.url)
        case .markdown:
            TextDocumentView(url: item.url, renderMarkdown: true)
        case .text:
            TextDocumentView(url: item.url, renderMarkdown: false)
        case .other:
            QuickLookView(url: item.url)
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                model.isViewerPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close viewer (Esc)")

            if model.canTrashSelection {
                Button {
                    model.moveToTrash()
                } label: {
                    Image(systemName: "trash")
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                // ⌘⌫ itself is owned by the single menu-bar command (see
                // LoupeApp); this stays a clickable button and shows the key as
                // a hint. Having one shortcut owner is what makes ⌘⌫ reliable.
                // Keep it out of the focus ring so a focused trash button can't
                // be fired by Space (which must stay owned by the viewer).
                .focusable(false)
                .help(isMulti ? "Move \(items.count) items to Trash (⌘⌫)" : "Move to Trash (⌘⌫)")
            }

            Spacer()

            if showingSingleImage {
                zoomControls
            } else if isMulti {
                Text("Grid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if canShowFilmStrip {
                if showingSingleImage {
                    Divider().frame(height: 16).overlay(Color.white.opacity(0.2))
                }
                filmStripToggle
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.08))
    }

    /// Toggle button for the film strip's visibility.
    private var filmStripToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                model.toggleFilmStrip()
            }
        } label: {
            Image(systemName: model.isFilmStripVisible ? "rectangle.bottomthird.inset.filled" : "rectangle")
                .font(.body)
                .foregroundStyle(model.isFilmStripVisible ? Color.accentColor : .white)
                .padding(6)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .help(model.isFilmStripVisible ? "Hide film strip (T)" : "Show film strip (T)")
    }

    /// Zoom toolbar for the single-image viewer: zoom out / level / zoom in,
    /// plus Fit and 100% buttons.
    private var zoomControls: some View {
        HStack(spacing: 8) {
            zoomButton("minus.magnifyingglass", command: .zoomOut, help: "Zoom out (⌘− or −)")

            Text("\(Int((zoomFactor * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 56)

            zoomButton("plus.magnifyingglass", command: .zoomIn, help: "Zoom in (⌘+ or +)")

            Divider().frame(height: 16).overlay(Color.white.opacity(0.2))

            pillButton("Fit", help: "Fit image to the view (⌘0 or Z)") { zoomCommand = .fit }

            pillButton("100%", help: "Actual pixel size (⌘1 or 1)") { zoomCommand = .actualSize }
        }
    }

    /// Invisible buttons carrying the zoom keyboard shortcuts for the single
    /// image viewer. Both the macOS-standard ⌘-based shortcuts and the bare
    /// single-key alternates are provided. Kept out of `zoomControls` so each
    /// shortcut is registered exactly once even though some keys repeat.
    @ViewBuilder
    private var zoomHotkeys: some View {
        ZStack {
            // Zoom in: ⌘+, ⌘=, and bare = / +
            hotkey("=", [.command]) { zoomCommand = .zoomIn }
            hotkey("+", [.command]) { zoomCommand = .zoomIn }
            hotkey("=", []) { zoomCommand = .zoomIn }
            hotkey("+", []) { zoomCommand = .zoomIn }

            // Zoom out: ⌘- and bare -
            hotkey("-", [.command]) { zoomCommand = .zoomOut }
            hotkey("-", []) { zoomCommand = .zoomOut }

            // Fit: ⌘0 and bare Z (bare F now flags, matching the grid).
            hotkey("0", [.command]) { zoomCommand = .fit }
            hotkey("z", []) { zoomCommand = .fit }

            // Actual size (100%): ⌘1 and bare 1
            hotkey("1", [.command]) { zoomCommand = .actualSize }
            hotkey("1", []) { zoomCommand = .actualSize }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Invisible buttons that map the number row to a percentage of the video's
    /// duration: 1→10%, 2→20%, … 9→90%, and 0→start (0%). Only mounted for a
    /// single video/audio item, so they never clash with the image zoom keys.
    @ViewBuilder
    private var percentageSeekHotkeys: some View {
        ZStack {
            ForEach(0..<10, id: \.self) { digit in
                hotkey(KeyEquivalent(Character("\(digit)")), []) {
                    videoController?.seek(toFraction: Double(digit) / 10.0)
                }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Viewer-wide letter hotkeys: J/L step between items, F or I flags the
    /// current item. For a single video/audio item, K toggles play/pause, U/O
    /// skip back/forward 15 seconds, and ,/. step one frame back/forward.
    ///
    /// J/L (and, for a multi-selection, the arrow keys) page by the current
    /// selection's size: with 3 images open side by side, Right selects the
    /// next 3 and Left the previous 3. `moveSelectionBlock` falls back to a
    /// single-item step when one or zero items are selected.
    @ViewBuilder
    private var navigationHotkeys: some View {
        ZStack {
            hotkey("j", []) { model.moveSelectionBlock(by: -1) }
            hotkey("l", []) { model.moveSelectionBlock(by: 1) }
            // ←/→ (plain = page the set, Shift = grow/shrink the selection) are
            // handled centrally via `.onKeyPress` on the viewer so the plain
            // and Shift variants disambiguate reliably.
            // F, I and S all flag the current item, matching the grid's flag
            // keys.
            hotkey("f", []) { model.toggleFlag() }
            hotkey("i", []) { model.toggleFlag() }
            hotkey("s", []) { model.toggleFlag() }
            // ⌃1–⌃5 apply color tags, matching the grid. Carried here so the
            // keys work from inside the viewer too.
            ForEach(Array(ColorTag.allInHotkeyOrder.enumerated()), id: \.element) { index, tag in
                hotkey(KeyEquivalent(Character("\(index + 1)")), .control) {
                    model.toggleColorTag(tag)
                }
            }
            if showingSingleVideo {
                hotkey("k", []) { videoController?.togglePlay() }
                hotkey("u", []) { videoController?.skip(by: -15) }
                hotkey("o", []) { videoController?.skip(by: 15) }
                hotkey(",", []) { videoController?.stepFrame(by: -1) }
                hotkey(".", []) { videoController?.stepFrame(by: 1) }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func hotkey(_ key: KeyEquivalent, _ modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(key, modifiers: modifiers)
            // Keep these invisible shortcut buttons out of the focus ring. If
            // one of them held keyboard focus, AppKit would let Space activate
            // the focused button directly — e.g. the trash hotkey below would
            // fire on Space, deleting the shown item instead of being handled
            // by the viewer's own `.onKeyPress(.space)`. The key equivalent
            // still dispatches without focus, so the shortcut keeps working.
            .focusable(false)
    }

    /// Hidden ⌘⌫ shortcut for "Move to Trash" while the viewer is open.
    /// Disabled (releasing the shortcut) when there's nothing to trash.
    @ViewBuilder
    private var trashHotkey: some View {
        hotkey(.deleteBackspace, .command) { model.moveToTrash() }
            .disabled(!model.canTrashSelection)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// Hidden ⌘C shortcut to copy the shown item(s) to the clipboard while the
    /// viewer owns focus, mirroring how the viewer carries its own ⌘⌫.
    @ViewBuilder
    private var copyHotkey: some View {
        hotkey("c", .command) { model.copyToClipboard() }
            .disabled(!model.canCopySelection)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// A clearly-tappable pill button for the dark viewer toolbar.
    private func pillButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.white.opacity(0.15), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func zoomButton(_ symbol: String, command: ZoomCommand, help: String) -> some View {
        Button {
            zoomCommand = command
        } label: {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.white)
                .padding(6)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func navButton(symbol: String, offset: Int) -> some View {
        // Only meaningful when viewing a single item; stepping walks the whole
        // displayed set.
        Button {
            model.moveSelection(by: offset)
        } label: {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.white)
                .padding(14)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        // Arrow-key navigation is handled centrally via `.onKeyPress` on the
        // viewer (see `handleArrow`) so plain and Shift arrows disambiguate;
        // these buttons stay click-only.
    }
}

// MARK: - Key handling

/// Bundles the viewer's Space and Left/Right arrow key handling into a single
/// modifier. Collapsing three `onKeyPress` calls into one keeps `MediaViewer`'s
/// already-large modifier chain within the Swift type-checker's limit.
private struct ViewerKeyHandling: ViewModifier {
    let onSpace: () -> Void
    let onArrow: (_ forward: Bool, _ shift: Bool) -> KeyPress.Result

    func body(content: Content) -> some View {
        content
            .onKeyPress(.space) {
                onSpace()
                return .handled
            }
            // A single general handler (which receives the full `KeyPress`) is
            // used for the arrows so we can read the Shift modifier precisely —
            // the key-specific `onKeyPress(_:action:)` overload takes a
            // zero-argument action and can't tell plain from Shift.
            .onKeyPress { keyPress in
                switch keyPress.key {
                case .leftArrow:
                    return onArrow(false, keyPress.modifiers.contains(.shift))
                case .rightArrow:
                    return onArrow(true, keyPress.modifiers.contains(.shift))
                default:
                    return .ignored
                }
            }
    }
}

// MARK: - Multi-selection grid

/// A grid of previews shown when multiple items are selected. The grid picks
/// the row/column split that makes each cell as large as possible for the
/// available space, filling the viewport instead of scrolling.
private struct MultiGrid: View {
    @Bindable var model: BrowserModel
    let items: [MediaItem]

    private let gap: CGFloat = 12
    private let outerPadding: CGFloat = 16
    private let captionHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let layout = bestLayout(
                count: items.count,
                in: CGSize(
                    width: max(1, geo.size.width - outerPadding * 2),
                    height: max(1, geo.size.height - outerPadding * 2)
                )
            )
            VStack(spacing: gap) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<layout.cols, id: \.self) { col in
                            let index = row * layout.cols + col
                            if index < items.count {
                                cell(items[index])
                            } else {
                                // Keep the grid shape with empty slots.
                                Color.clear
                            }
                        }
                    }
                }
            }
            .padding(outerPadding)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Number keys flag/unflag an individual tile: 1 → first image, 2 →
        // second, … up to 9. Each key targets its specific item regardless of
        // the (whole-set) selection, so a single press toggles just that tile.
        .background { flagHotkeys }
    }

    /// Invisible shortcut buttons mapping digits 1–9 to the matching tile's
    /// flag toggle. Only as many keys as there are visible items are mounted.
    @ViewBuilder
    private var flagHotkeys: some View {
        ZStack {
            ForEach(Array(items.prefix(9).enumerated()), id: \.element.id) { index, item in
                Button {
                    model.toggleFlag(id: item.id)
                } label: { EmptyView() }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                .focusable(false)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func cell(_ item: MediaItem) -> some View {
        VStack(spacing: 4) {
            // Tie the cell's identity to the item so its per-cell zoom state is
            // reset when a grid position maps to a different image, rather than
            // inheriting the previous item's zoom.
            GridPreview(item: item)
                .id(item.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) { cellBadges(for: item) }
            Text(item.name)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: captionHeight)
        }
    }

    /// Per-tile overlay: the position number (its flag hotkey) plus a flag
    /// badge when the tile is flagged, so the number-key mapping is discoverable
    /// and the flag state is visible at a glance.
    @ViewBuilder
    private func cellBadges(for item: MediaItem) -> some View {
        let position = items.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
        HStack(spacing: 4) {
            if let position, position <= 9 {
                Text("\(position)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.black.opacity(0.55), in: Circle())
            }
            if model.isFlagged(item.id) {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.orange, in: Circle())
            }
        }
        .padding(6)
    }

    /// Chooses the (rows, cols) split that maximizes the area of each cell,
    /// accounting for gaps and the per-cell caption height.
    private func bestLayout(count: Int, in size: CGSize) -> (rows: Int, cols: Int) {
        guard count > 1 else { return (1, max(1, count)) }

        var best = (rows: 1, cols: count)
        var bestArea: CGFloat = 0

        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cellW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let cellH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows) - captionHeight
            guard cellW > 0, cellH > 0 else { continue }
            let area = cellW * cellH
            if area > bestArea {
                bestArea = area
                best = (rows, cols)
            }
        }
        return best
    }
}

/// A preview used inside the multi-selection grid. Images are individually
/// zoomable/pannable (pinch or scroll-wheel to zoom, drag to pan); other kinds
/// use their native players/preview.
private struct GridPreview: View {
    let item: MediaItem

    // Per-cell zoom state so each image in the grid zooms independently.
    @State private var command: ZoomCommand?
    @State private var zoomFactor: CGFloat = 1

    var body: some View {
        switch item.kind {
        case .image:
            ZoomableImageView(url: item.url, command: $command, zoomFactor: $zoomFactor)
                .overlay(alignment: .bottomTrailing) { zoomBadge }
        case .video, .audio:
            VideoPlayerView(url: item.url)
        case .pdf:
            PDFViewerRepresentable(url: item.url)
        case .markdown:
            TextDocumentView(url: item.url, renderMarkdown: true)
        case .text:
            TextDocumentView(url: item.url, renderMarkdown: false)
        case .other:
            QuickLookView(url: item.url)
        }
    }

    /// Small live zoom readout / reset for a grid cell.
    private var zoomBadge: some View {
        Button {
            command = .fit
        } label: {
            Text("\(Int((zoomFactor * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Click to fit")
        .padding(6)
    }
}

// MARK: - Image

/// Scroll-to-zoom and drag-to-pan image view.
// MARK: - Video

// VideoPlayerView now lives in VideoPlayer.swift (controls sit below the video,
// not over it).

// MARK: - PDF

private struct PDFViewerRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        view.backgroundColor = .black
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - QuickLook fallback

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as QLPreviewItem
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as QLPreviewItem
        }
    }
}
