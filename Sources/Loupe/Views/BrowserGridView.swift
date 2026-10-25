import SwiftUI

/// The main content area: a scrollable grid of thumbnails.
struct BrowserGridView: View {
    @Bindable var model: BrowserModel
    /// When false (e.g. the search field is focused), the grid must not grab
    /// keyboard focus on appear, so typing in search is never interrupted.
    var canAutoFocus: Bool = true
    /// True while the toolbar search field holds keyboard focus. The grid keeps
    /// its own `.onKeyPress` handlers mounted even then (the content area can
    /// retain first responder alongside the toolbar field), so without this the
    /// grid would swallow keystrokes meant for the field — notably ⌘A, which
    /// the grid would turn into "select all items" instead of letting the field
    /// select its text. When true, `handleKey` ignores everything so the field
    /// gets native editing.
    var searchFocused: Bool = false

    @FocusState private var gridFocused: Bool
    /// The id a click just selected, so the auto-scroll (used for keyboard
    /// navigation) doesn't yank a clicked, already-visible item. Scoped to the
    /// specific id — not a bare "skip the next change" flag — so a selection
    /// that moves *away* from the clicked item (e.g. marking it flagged/tagged
    /// under a filter auto-advances to the next item) still scrolls to the new
    /// item instead of being wrongly suppressed.
    @State private var suppressScrollForID: MediaItem.ID?

    // Rubber-band (marquee) selection state, in the "grid" coordinate space.
    @State private var cellFrames: [URL: CGRect] = [:]
    @State private var marqueeRect: CGRect?
    /// True only while a marquee press/drag is active. Gates per-cell frame
    /// reporting (see `reportCellFrame`) so cells don't emit frame preferences
    /// on every ordinary scroll frame — the main scroll-performance cost.
    @State private var marqueeActive = false
    /// The most recent marquee rectangle, kept so the drag can be re-hit-tested
    /// against cell frames that only arrive after `marqueeActive` is armed (the
    /// `GeometryReader` frames reach `cellFrames` a layout pass later, via the
    /// preference round-trip). When those frames land mid-drag we redo the
    /// hit-test with this rect so the selection catches up instead of staying
    /// empty for the first frames — or, for a quick drag, never registering.
    @State private var lastMarqueeRect: CGRect?
    /// Set when a marquee drag ends (mouse-up) but the cell frames haven't
    /// arrived yet, so the final hit-test couldn't run. Keeps `marqueeActive`
    /// (and therefore frame reporting) alive past the drag so the pending
    /// `onPreferenceChange` can do one authoritative hit-test against the
    /// retained `lastMarqueeRect` the instant frames land, then tear down.
    /// Without this, a quick drag — or one over empty space whose frames hadn't
    /// been reported yet — tore everything down on mouse-up and selected
    /// nothing, which is why marquee selection appeared completely broken.
    @State private var marqueeEndPending = false

    private let gridSpace = "grid"
    /// The visible gap between adjacent images when filenames are shown. The
    /// cell adds 4pt of padding on every side, so with the 2pt grid spacing the
    /// image-to-image gap is 2 + 4 + 4 = 10pt. The tight image wall matches
    /// this so hiding filenames doesn't make the images suddenly crowd together.
    private static let shownImageGap: CGFloat = 10

    /// Gap between cells. Collapsed to zero when filenames are hidden so the
    /// image-only grid packs edge to edge (the cell's own padding also drops to
    /// zero there) — but only for fitted thumbnails, which letterbox and so
    /// don't visually touch. In fill mode the image is cropped to the full cell
    /// and the cell has no padding, so the grid spacing alone is the whole gap;
    /// use the same ~10pt gap as the filenames-shown layout so the spacing is
    /// consistent rather than collapsing to a near-touch 2pt.
    private var spacing: CGFloat {
        guard model.hideFilenames else { return 2 }
        return model.fillGridCells ? Self.shownImageGap : 0
    }
    private let padding: CGFloat = 8

    private var cellWidth: CGFloat { model.thumbnailSize + 12 }

    /// True for the edge-to-edge, cropped image wall: filenames hidden and
    /// thumbnails filled. In that mode we want a uniform gap in BOTH axes.
    private var isTightImageWall: Bool { model.hideFilenames && model.fillGridCells }

    private var columns: [GridItem] {
        // In the tight image-wall mode, use fixed-width columns sized to the
        // cell so the horizontal gap between images is exactly `spacing` — the
        // same as the vertical row gap. The adaptive layout (used everywhere
        // else) stretches columns to fill the width, which spreads the leftover
        // slack between images and makes the horizontal gaps wider than the
        // vertical ones. Fixed columns remove that slack so both axes match.
        if isTightImageWall {
            // Columns are exactly the cell's image width (`thumbnailSize`),
            // with no extra inset, so the only horizontal gap is `spacing` —
            // matching the vertical row gap. (The normal `cellWidth` adds 12pt
            // of breathing room, which would make the horizontal gap larger.)
            let count = max(1, liveColumnCount)
            return Array(
                repeating: GridItem(.fixed(model.thumbnailSize), spacing: spacing, alignment: .top),
                count: count
            )
        }
        return [GridItem(.adaptive(minimum: cellWidth), spacing: spacing)]
    }

    /// The grid content's width, frozen at its pre-drag value while the preview
    /// sidebar is being resized. Pinning the content width keeps the adaptive
    /// `LazyVGrid` from re-deriving its column count (and re-flowing/stretching
    /// every cell) as the panel squeezes the grid each tick. `nil` means "no
    /// freeze" — the content fills the available width normally.
    @State private var frozenContentWidth: CGFloat?

    /// Warms thumbnails for every item in the current displayed set, in order,
    /// at prefetch priority — so after the visible cells are generated the rest
    /// of the filtered folder keeps generating in the background instead of
    /// waiting for the user to scroll. Runs as a cancellable `.task`: a yield
    /// between items keeps the actor responsive and lets SwiftUI cancel the
    /// pass promptly when the displayed set changes (the id flips). The
    /// provider skips anything already cached or in flight, and `.visible`
    /// requests always preempt this, so it never delays on-screen cells.
    ///
    /// Suspended while a folder scan is in flight: the scan walks the directory
    /// tree sequentially, and on a slow/removable disk (external HDD) flooding
    /// the device with the warm pass's scattered thumbnail reads at the same
    /// time collapses throughput — both the scan and the thumbnails stall. The
    /// pass is keyed on `model.isScanning` (see `WarmAllKey`), so it simply
    /// doesn't enqueue anything until the scan finishes, then starts with the
    /// disk to itself. Visible cells are unaffected: they request at `.visible`
    /// directly from their own cell task, not through this pass.
    private func warmRemainingThumbnails() async {
        // Don't compete with an in-flight scan for the disk. When scanning ends
        // the key flips and this task re-runs to warm the settled set.
        guard !model.isScanning else { return }

        let items = model.visualOrderItems
        guard !items.isEmpty else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: model.thumbnailSize, height: model.thumbnailSize)
        let method = model.thumbnailMethod
        let videoPosition = model.videoThumbnailPosition
        for item in items {
            if Task.isCancelled { return }
            await ThumbnailProvider.shared.prefetch(
                item.url, size: target, scale: scale,
                method: method, videoPosition: videoPosition
            )
            // Yield so a burst of enqueues doesn't monopolize the actor and so
            // cancellation (on a display change) is observed promptly.
            await Task.yield()
        }
    }

    /// The cell id to scroll to for a selected item. Cells carry a string id —
    /// the item's own id in the flat grid, or a per-occurrence composite
    /// group+item id when grouping is active — so a bare selected id must be
    /// resolved to the matching cell. In a grouped grid the same photo can
    /// appear under several sections; we target its FIRST occurrence (the
    /// earliest in display order), matching where navigation treats the item as
    /// living (see `visualOrderItems`, which keeps each item once at its first
    /// position).
    private func scrollTarget(for id: MediaItem.ID) -> String? {
        guard model.grouping != .none else { return id.absoluteString }
        for group in model.groupedDisplayedItems {
            if let item = group.items.first(where: { $0.id == id }) {
                return BrowserModel.CategoryGroup.Entry(groupID: group.id, item: item).id
            }
        }
        return nil
    }

    /// A single grid cell: the thumbnail plus all its selection, drag and
    /// context-menu wiring. Shared by the flat and grouped layouts so both
    /// behave identically.
    @ViewBuilder
    private func cell(for item: MediaItem, cellID: String) -> some View {
        ThumbnailView(
            item: item,
            size: model.thumbnailSize,
            isSelected: model.selectedItems.contains(item.id),
            isFlagged: model.isFlagged(item.id),
            isHidden: model.isHidden(item.id),
            colorTag: model.colorTag(item.id),
            aiCategory: model.aiCategory(item.id),
            textTags: model.textTags(item.id),
            personCount: model.persons(item.id).count,
            hideFilename: model.hideFilenames,
            fill: model.fillGridCells,
            method: model.thumbnailMethod,
            videoPosition: model.videoThumbnailPosition
        )
        // Per-occurrence SwiftUI identity. In the flat grid this is the item's
        // own id; in a grouped (e.g. person) grid the SAME photo can appear in
        // several sections, so each occurrence gets a composite group+item id.
        // Using the bare `item.id` here instead would give two cells in the one
        // LazyVGrid the same explicit identity — SwiftUI then can't tell them
        // apart and a selection change refreshes only one of the colliding
        // cells, so the other shows no highlight. That's the "selected item
        // sometimes isn't highlighted" bug. The ScrollViewReader targets this
        // same id (see `scrollTarget`) so auto-scroll still resolves to a real
        // cell in both layouts.
        .id(cellID)
        // As the grid instantiates this cell (which LazyVGrid does just before
        // it scrolls into view), warm the next few items at low priority so a
        // continued scroll finds them ready. Visible cells still take priority.
        .reportCellFrame(id: item.id, in: gridSpace, active: marqueeActive)
        .contentShape(Rectangle())
        // AppKit-level click handling: selection fires on mouse-down with no
        // double-click delay. Command toggles, Shift extends a range.
        .onClick(
            single: { mods in
                if mods.command {
                    // A ⌘-click that removes the primary item from the
                    // selection makes some *other* already-selected item the
                    // new primary (`selectedItem` moves to it). That's a
                    // side-effect of deselecting, not a navigation, so it must
                    // not scroll. Since the scroll is suppressed only for the id
                    // the selection lands on, predict that id — the next
                    // surviving selected item — and suppress it. (An ordinary
                    // ⌘-click that *adds* or deselects a non-primary item lands
                    // on this clicked item, so suppressing its id is correct
                    // there too.)
                    let deselectingPrimary = model.selectedItem == item.id
                        && model.selectedItems.contains(item.id)
                    if deselectingPrimary {
                        suppressScrollForID = model.selectedItems.first { $0 != item.id }
                    } else {
                        suppressScrollForID = item.id
                    }
                    model.toggleSelection(item.id)
                } else if mods.shift {
                    suppressScrollForID = item.id
                    model.extendSelection(to: item.id)
                } else {
                    suppressScrollForID = item.id
                    model.selectOnly(item.id)
                }
                gridFocused = true
            },
            double: { _ in
                suppressScrollForID = item.id
                if !model.selectedItems.contains(item.id) {
                    model.selectOnly(item.id)
                }
                model.isViewerPresented = true
            },
            dragURLs: { dragURLs(for: item) },
            isSelected: { model.selectedItems.contains(item.id) }
        )
        .contextMenu { contextMenu(for: item) }
    }

    /// A pinned category section header: the category name, an item count, and
    /// A pinned section header. Clicking it collapses or expands the section;
    /// a leading chevron rotates to show the state.
    @ViewBuilder
    private func sectionHeader(_ group: BrowserModel.CategoryGroup) -> some View {
        let collapsed = model.isGroupCollapsed(group.id)
        Button {
            model.toggleGroupCollapsed(group.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Image(systemName: group.symbol)
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(group.isResidual ? .secondary : .primary)
                Text("\(group.items.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.bar)
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand group" : "Collapse group")
    }

    /// Vertical gap below each group (except the last) that separates adjacent
    /// sections in the grouped grid.
    private static let groupSpacing: CGFloat = 20

    /// How many seconds O / U step the preview sidebar's video.
    private static let previewSeekSeconds: Double = 5

    /// Number of columns that fit in a given width, matching the adaptive grid.
    /// Used as a fallback before any cells have reported their frames.
    private func columnCount(for width: CGFloat) -> Int {
        let usable = width - padding * 2
        guard usable > 0 else { return 1 }
        // Match whichever column width the active layout uses, so the estimated
        // count agrees with how many columns actually get laid out: the tight
        // image wall uses fixed `thumbnailSize`-wide columns, every other mode
        // the adaptive `cellWidth` minimum.
        let perColumn = isTightImageWall ? model.thumbnailSize : cellWidth
        let count = Int((usable + spacing) / (perColumn + spacing))
        return max(1, count)
    }

    /// The number of columns actually on screen, derived from the rendered cell
    /// frames rather than a width estimate. The adaptive `LazyVGrid` decides the
    /// real column count internally, and an external window-snapping tool can
    /// resize the grid without the width-based `onChange` producing a count that
    /// matches what SwiftUI laid out.
    ///
    /// We take the *widest* instantiated row — the most cells sharing a single
    /// `minY` — not simply the topmost row. `cellFrames` only holds the cells
    /// LazyVGrid has realized (roughly the viewport), and with grouping the top
    /// realized row is often a partial row: the tail of a section scrolled just
    /// off the top, or a section's short first/last row. Counting a partial row
    /// yields too few columns and throws off every Up/Down jump. A full row has
    /// the true column count, and at least one is almost always realized, so the
    /// maximum row width is the reliable signal. Falls back to the cached
    /// estimate until frames are reported.
    private var liveColumnCount: Int {
        Self.columnCount(from: cellFrames, fallback: max(1, model.gridColumnCount))
    }

    /// Bucket cells into rows by shared minY (tolerance absorbs sub-pixel
    /// drift), then take the widest row's cell count. Static so it can be
    /// computed from freshly-reported frames before the `@State` settles.
    private static func columnCount(from frames: [MediaItem.ID: CGRect], fallback: Int) -> Int {
        guard !frames.isEmpty else { return fallback }
        let tolerance: CGFloat = 1
        let sortedMinY = frames.values.map(\.minY).sorted()
        var widest = 1
        var rowStartY = sortedMinY[0]
        var rowCount = 0
        for y in sortedMinY {
            if y - rowStartY <= tolerance {
                rowCount += 1
            } else {
                widest = max(widest, rowCount)
                rowStartY = y
                rowCount = 1
            }
        }
        widest = max(widest, rowCount)
        return max(1, widest)
    }

    var body: some View {
        let items = model.displayedItems
        Group {
            if items.isEmpty {
                emptyState
                    // Fill the available area so the surrounding VStack keeps
                    // the filter bar pinned to the top instead of centering it
                    // vertically alongside a compact empty-state view.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: spacing, pinnedViews: [.sectionHeaders]) {
                                if model.grouping != .none {
                                    // Grouped: one section per category/person,
                                    // with a pinned header. Cells warm by their
                                    // position in the full display order
                                    // (globalIndex) so prefetch spans sections.
                                    // A person can appear in several sections, so
                                    // each cell's SwiftUI identity is scoped to
                                    // its group to avoid duplicate-id collisions.
                                    let groups = model.groupedDisplayedItems
                                    ForEach(Array(groups.enumerated()),
                                            id: \.element.id) { groupIndex, group in
                                        Section {
                                            // Composite data identity (group +
                                            // item) so a person who appears in
                                            // several sections doesn't produce
                                            // duplicate ForEach identities within
                                            // the one LazyVGrid. A collapsed
                                            // section renders only its header.
                                            if !model.isGroupCollapsed(group.id) {
                                                ForEach(group.entries) { entry in
                                                    cell(for: entry.item, cellID: entry.id)
                                                }
                                            }
                                        } header: {
                                            sectionHeader(group)
                                        } footer: {
                                            // Gap below every group but the
                                            // last. A footer spans the full grid
                                            // width and isn't pinned, so the next
                                            // header still sticks flush to top.
                                            if groupIndex < groups.count - 1 {
                                                Color.clear.frame(height: Self.groupSpacing)
                                            }
                                        }
                                    }
                                } else {
                                    // `ForEach(items)` (MediaItem is Identifiable)
                                    // avoids allocating an N-element enumerated
                                    // array on every grid re-render.
                                    ForEach(items) { item in
                                        cell(for: item, cellID: item.id.absoluteString)
                                    }
                                }
                            }
                            .padding(padding)
                            // Rebuild the grid when the grouped layout's shape
                            // changes (a section appears/disappears/resizes —
                            // e.g. a rename reshuffles filename-prefix buckets)
                            // so the LazyVGrid remeasures its scrollable extent.
                            // Otherwise it can keep a stale, too-short content
                            // height after the sections change beneath it,
                            // leaving the bottom groups unreachable by scrolling.
                            // Keyed to the shape only (ids + counts + collapsed),
                            // so unrelated display ticks don't reset scroll.
                            .id(model.groupLayoutSignature)
                            // While the sidebar is resizing, pin the content to
                            // its pre-drag width and keep it leading-aligned so
                            // the adaptive grid doesn't re-flow as the panel
                            // squeezes the column; otherwise fill the width.
                            .modifier(GridContentWidth(
                                frozenWidth: frozenContentWidth,
                                minHeight: geo.size.height
                            ))
                            // Marquee layer sits behind the cells (AppKit-level,
                            // so the scroll view never sees the drag): a drag
                            // beginning on empty space rubber-band-selects; drags
                            // on a cell are consumed by the cell's own overlay.
                            .background(
                                MarqueeView(
                                    onDragBegan: {
                                        // Arm per-cell frame reporting for the
                                        // duration of this press so the first
                                        // drag rect can hit-test fresh frames.
                                        // Clear any leftover pending-end state
                                        // from a prior drag so this one starts
                                        // clean.
                                        marqueeEndPending = false
                                        lastMarqueeRect = nil
                                        if !marqueeActive { marqueeActive = true }
                                    },
                                    onChange: { rect in handleMarquee(rect) },
                                    onEmptyClick: {
                                        gridFocused = true
                                        model.clearSelection()
                                    }
                                )
                            )
                            .overlay(marqueeRectangle)
                            // Anchor the grid coordinate space on the content
                            // view itself — the same view the MarqueeView backs
                            // and the cells live in — so the marquee rect (in
                            // that view's local coordinates) and the reported
                            // cell frames share one origin. Anchoring it on the
                            // enclosing ScrollView instead made the two diverge
                            // once the content scrolled or pinned section
                            // headers shifted layout, so the marquee selected
                            // items offset below the dragged rectangle.
                            .coordinateSpace(name: gridSpace)
                        }
                        .onPreferenceChange(CellFramesKey.self) { frames in
                            cellFrames = frames
                            // Frames arrive a layout pass after a marquee drag
                            // arms `marqueeActive`, so the drag's first ticks ran
                            // against an empty `cellFrames` and selected nothing.
                            // Now that fresh frames have landed, redo the
                            // hit-test against the live rect so the selection
                            // catches up — this is also what makes a quick drag
                            // (released before the first frames arrived) still
                            // register, because the rect is retained.
                            if marqueeActive, let rect = lastMarqueeRect, !frames.isEmpty {
                                let hits = frames.compactMap {
                                    $0.value.intersects(rect) ? $0.key : nil
                                }
                                model.setSelection(hits)
                                // If the drag already ended (mouse-up came
                                // before these frames landed), this was the
                                // deferred authoritative hit-test: finalize and
                                // stop reporting now that the selection is set.
                                if marqueeEndPending {
                                    finishMarquee()
                                }
                            } else if marqueeEndPending {
                                // The drag ended and frames resolved to empty
                                // (no realized cells overlapped the rubber
                                // band): the selection is nothing. Clear it and
                                // finalize so frame reporting stops instead of
                                // staying armed forever.
                                model.setSelection([])
                                finishMarquee()
                            }
                            // Don't republish the column count mid-resize: the
                            // grid is frozen to a fixed count then, and the
                            // cells are mid-reflow so the frame-derived count
                            // would be noisy. The committed count is recomputed
                            // once the drag ends and the layout settles.
                            guard !model.isResizingPreviewSidebar else { return }
                            // Publish the accurate, rendered column count so
                            // other surfaces (e.g. the tag overlay's Up/Down
                            // navigation) jump exactly one row. Computed from
                            // the freshly-reported frames (not `liveColumnCount`,
                            // which reads the not-yet-settled @State). The
                            // width-based estimate elsewhere is only a fallback
                            // before frames arrive; it tends to be too small and
                            // threw off Up/Down when read from outside the grid.
                            let live = Self.columnCount(from: frames,
                                                        fallback: max(1, model.gridColumnCount))
                            if model.gridColumnCount != live {
                                model.gridColumnCount = live
                            }
                        }
                        .onChange(of: model.selectedItem) { _, newValue in
                            // Never auto-scroll while a marquee drag is in
                            // flight: it updates the selection continuously, and
                            // scrolling to the moving anchor would yank the grid
                            // under the user's drag. `marqueeRect` is non-nil
                            // only during the drag.
                            if marqueeRect != nil { return }
                            // A click lands on an already-visible item, so skip
                            // the scroll for THAT item only. Any other change —
                            // including an auto-advance after marking the
                            // clicked item (which moves the selection to the
                            // next item, especially under a filter that hides
                            // the one just marked) — should still scroll. The
                            // one-shot is cleared either way.
                            let clicked = suppressScrollForID
                            suppressScrollForID = nil
                            if let newValue, newValue == clicked { return }
                            // Cells are identified by a string id (the item's
                            // own id when flat, a composite group+item id when
                            // grouped), so translate the selected item into the
                            // matching cell id before scrolling.
                            if let newValue, let target = scrollTarget(for: newValue) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    proxy.scrollTo(target, anchor: .center)
                                }
                            }
                        }
                        // When the displayed set changes (notably as a search
                        // query is typed) the selected item can survive the
                        // filter without `selectedItem` changing — so the
                        // `onChange(of: selectedItem)` above never fires, and a
                        // survivor that LazyVGrid hasn't realized stays
                        // unhighlighted off-screen. Re-target the scroll at the
                        // current selection whenever the display revision bumps
                        // so the selected cell is realized and shows its
                        // highlight. Marquee drags and the per-click suppress
                        // one-shot are honored just like the selection handler.
                        .onChange(of: model.displayRevision) { _, _ in
                            guard marqueeRect == nil else { return }
                            guard let sel = model.selectedItem else { return }
                            // Defer to the next runloop tick so the grid has
                            // realized its new content before we scroll. When an
                            // annotation removes the selected cell from the
                            // filtered set (e.g. flagging under the "Unmarked"
                            // Library view, which auto-advances to the next
                            // item), the display mutation and the new selection
                            // land in the same update pass; scrolling inline
                            // resolves against the old, taller layout and the
                            // LazyVGrid then snaps to the top. Waiting a tick
                            // lets the successor cell exist so the scroll targets
                            // it and keeps it in view. The selection is re-read
                            // in the deferred block so a rapid follow-up change
                            // wins.
                            DispatchQueue.main.async {
                                guard marqueeRect == nil,
                                      let current = model.selectedItem,
                                      current == sel,
                                      let target = scrollTarget(for: current) else { return }
                                // No animation here: a filter change is a layout
                                // jump, not a cursor move, so snap rather than
                                // glide.
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                        // The grid subtree is torn down and rebuilt whenever the
                        // displayed set passes through empty and back — which
                        // happens repeatedly while typing a search query, as an
                        // intermediate keystroke matches nothing. On the rebuild
                        // LazyVGrid only realizes the cells near the top, so a
                        // still-selected survivor that's scrolled off never
                        // repaints its highlight. Scroll it back into view as
                        // the subtree reappears so the selection stays visible.
                        .onAppear {
                            guard let sel = model.selectedItem,
                                  let target = scrollTarget(for: sel) else { return }
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                    .onChange(of: geo.size.width, initial: true) { _, width in
                        // Don't recompute the column count mid-resize: the grid
                        // is frozen then, and churning this observable would
                        // re-render the grid on every tick.
                        guard !model.isResizingPreviewSidebar else { return }
                        model.gridColumnCount = columnCount(for: width)
                    }
                    .onChange(of: model.isResizingPreviewSidebar) { _, resizing in
                        // At the start of a sidebar resize, freeze the content
                        // to its current width so the adaptive grid stops
                        // re-flowing as the panel squeezes it. Clear the freeze
                        // when the drag ends and let it relayout once.
                        if resizing {
                            // The frame is applied after `.padding(padding)`, so
                            // pin it to the full pre-drag grid width.
                            frozenContentWidth = geo.size.width
                        } else {
                            frozenContentWidth = nil
                        }
                    }
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                // When the displayed set changes (switching the selected
                // folder, a chip filter, search, sort, or Library-view switch),
                // retarget thumbnail generation at the new displayed set: cancel
                // in-flight work for items no longer shown so it stops occupying
                // the scheduler ahead of what's now on screen. Items still
                // displayed keep their work; vanished items (including the
                // previous folder's on-screen cells) yield their slots. Keyed on
                // the cheap `displayRevision` token, not the item array.
                .onChange(of: model.displayRevision) { _, _ in
                    let keep = Set(model.displayedItems.map(\.url))
                    Task { await ThumbnailProvider.shared.cancelInFlight(notIn: keep) }
                }
                // Background pass: once the on-screen cells have what they need,
                // keep warming the REST of the currently displayed set at low
                // priority so the whole filtered folder ends up generated
                // without the user having to scroll through it. Keyed on the
                // display state (set + thumbnail options) so it restarts — and,
                // via `.task`, cancels the previous pass — whenever the filter,
                // folder, or thumbnail method changes. The provider dedupes
                // (cached / in-flight items are skipped) and always serves
                // `.visible` cells ahead of this, so it never delays what's on
                // screen.
                .task(id: WarmAllKey(
                    revision: model.displayRevision,
                    method: model.thumbnailMethod,
                    videoPosition: model.videoThumbnailPosition,
                    size: model.thumbnailSize,
                    isScanning: model.isScanning
                )) {
                    await warmRemainingThumbnails()
                }
                // Only auto-focus when permitted. This branch reappears every
                // time search results return after being empty, so grabbing
                // focus unconditionally here would steal it from the search
                // field mid-type.
                .onAppear {
                    if canAutoFocus && !model.isSearchFieldFocused { gridFocused = true }
                }
                // Reclaim keyboard focus when the displayed set changes while
                // the grid stays mounted. Annotating the selected item under a
                // Library filter that hides it (e.g. flagging under "Unmarked")
                // auto-advances the selection to the next item, but removing the
                // old selected cell from the LazyVGrid tears out the responder
                // that held first responder, so arrow keys go dead until the
                // user clicks a cell. Re-asserting focus here keeps keyboard
                // navigation flowing, mirroring the viewer/tag-input reclaim
                // below. Gated so it never steals focus from the search field or
                // while an overlay owns the keyboard. Deferred a tick so it runs
                // after the grid has rebuilt its content.
                .onChange(of: model.displayRevision) { _, _ in
                    guard canAutoFocus, !searchFocused,
                          !model.isViewerPresented, !model.showTagInput else { return }
                    // Re-check the *live* search-focus flag at execution time:
                    // typing in the search field bumps `displayRevision`, and
                    // the `searchFocused` parameter captured above can still be
                    // stale on the first keystroke/click. Reading the model here
                    // stops this deferred reclaim from stealing the field's
                    // focus the moment it's granted.
                    DispatchQueue.main.async {
                        guard !model.isSearchFieldFocused else { return }
                        gridFocused = true
                    }
                }
                // Reclaim keyboard focus when the viewer closes. The grid stays
                // mounted beneath the viewer overlay, so its `.onAppear` never
                // fires again on dismiss; without this the arrow keys stay dead
                // until the user clicks a cell. Deferred a runloop tick so the
                // viewer has fully relinquished focus first.
                .onChange(of: model.isViewerPresented) { _, presented in
                    if !presented && canAutoFocus {
                        DispatchQueue.main.async { gridFocused = true }
                    }
                }
                // Likewise reclaim focus when the tag-input overlay closes. Its
                // text field takes first responder while open, so on dismiss
                // the grid would otherwise stay unfocused and arrow-key
                // navigation would be dead until the user clicks a cell.
                .onChange(of: model.showTagInput) { _, showing in
                    if !showing && canAutoFocus && !model.isViewerPresented {
                        DispatchQueue.main.async { gridFocused = true }
                    }
                }
                // Arrow keys get their own handler, matched on the specific
                // keys. This is what makes them take precedence over the
                // enclosing ScrollView's built-in arrow-key scrolling —
                // ↑/↓ would otherwise scroll the grid instead of moving the
                // selection (←/→ have no scroll action, which is why only
                // up/down appeared broken). The KeyPress still carries the
                // modifiers, so Shift-extend keeps working.
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow,
                                   "i", "j", "k", "l", "o", "u"]) { press in
                    handleKey(press)
                }
                // Everything else (⌘A, F) via a catch-all handler.
                .onKeyPress { press in handleKey(press) }
            }
        }
    }

    /// Shown when nothing matches the current scope/filters. Kept as a separate
    /// view so it can be given an expanding frame; a bare `ContentUnavailableView`
    /// in a `VStack` sizes to its content and lets siblings drift to the middle.
    @ViewBuilder
    private var emptyState: some View {
        if model.hasActiveChipFilters && !model.scopedItems.isEmpty {
            ContentUnavailableView(
                "No Matching Files",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No files match the selected type/extension filters.")
            )
        } else if model.showFlaggedOnly {
            ContentUnavailableView(
                "No Flagged Files",
                systemImage: "flag",
                description: Text("Flag files with F to see them here, or turn off the flagged filter.")
            )
        } else if model.showHiddenOnly {
            ContentUnavailableView(
                "No Hidden Files",
                systemImage: "eye.slash",
                description: Text("Hide files with ⌫ to see them here, or pick All Media.")
            )
        } else if let tag = model.colorTagFilter {
            ContentUnavailableView(
                "No \(tag.displayName) Files",
                systemImage: tag.symbol,
                description: Text("Tag files with ⌃ and a number to see them here, or pick All Media.")
            )
        } else {
            ContentUnavailableView(
                "Nothing Here",
                systemImage: "photo.on.rectangle.angled",
                description: Text(model.mode == .folders
                    ? "This folder has no files."
                    : "The dropped folder has no files.")
            )
        }
    }

    // MARK: - Marquee (rubber-band) selection

    /// A transparent background that captures drags starting on empty space and
    /// turns them into a rubber-band selection.
    /// The visible selection rectangle while dragging.
    @ViewBuilder
    private var marqueeRectangle: some View {
        if let rect = marqueeRect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    /// File URLs to drag out when dragging `item`: the whole selection if the
    /// item is part of it, otherwise just that item.
    private func dragURLs(for item: MediaItem) -> [URL] {
        if model.selectedItems.contains(item.id) {
            return model.selectedMediaItems.map(\.url)
        }
        return [item.url]
    }

    /// Called by the AppKit marquee layer: `rect` is the live rectangle, or nil
    /// when the drag ends.
    private func handleMarquee(_ rect: CGRect?) {
        marqueeRect = rect
        guard let rect else {
            // Bare press with no drag (`lastMarqueeRect` never set): there's no
            // rubber band to hit-test, so finalize immediately. Without this the
            // marquee stayed "active" after a plain background click, which kept
            // per-cell frame reporting armed indefinitely. (The separate
            // `onEmptyClick` path clears the selection for this case.)
            guard lastMarqueeRect != nil else {
                finishMarquee()
                return
            }
            // Drag ended. The cell frames are reported a layout pass AFTER
            // `marqueeActive` armed on mouse-down, and SwiftUI holds those
            // layout/preference updates until the run loop turns — which, for a
            // quick drag, can be after this mouse-up. So `cellFrames` is
            // frequently still empty right here.
            if let lastMarqueeRect, !cellFrames.isEmpty {
                // Frames are present: do the authoritative final hit-test now
                // and tear the marquee state down.
                let hits = cellFrames.compactMap {
                    $0.value.intersects(lastMarqueeRect) ? $0.key : nil
                }
                model.setSelection(hits)
                finishMarquee()
            } else {
                // Frames haven't landed yet. DON'T tear down — keep
                // `marqueeActive` (hence frame reporting) alive and flag the
                // end as pending. The next `onPreferenceChange`, once frames
                // arrive, runs the final hit-test against the retained
                // `lastMarqueeRect` and then calls `finishMarquee`. This is the
                // fix for marquee selection selecting nothing: the old code
                // tore everything down here before the frames could arrive.
                marqueeEndPending = true
            }
            return
        }
        gridFocused = true
        lastMarqueeRect = rect
        // Auto-scroll is suppressed for the whole drag via `marqueeRect != nil`
        // in the selection `onChange`, so no one-shot flag is needed here.
        // `cellFrames` may still be empty on the first few ticks (the frames
        // are reported a layout pass after `marqueeActive` armed); the
        // `onPreferenceChange` above redoes this hit-test the moment they land,
        // so the selection catches up rather than staying empty.
        let hits = cellFrames.compactMap { $0.value.intersects(rect) ? $0.key : nil }
        model.setSelection(hits)
    }

    /// Tear down the marquee state once a drag has fully resolved (either the
    /// final hit-test ran at mouse-up, or it ran later from `onPreferenceChange`
    /// once the deferred frames arrived). Stops per-cell frame reporting so
    /// ordinary scrolling pays nothing again.
    private func finishMarquee() {
        lastMarqueeRect = nil
        marqueeEndPending = false
        marqueeActive = false
        cellFrames = [:]
    }

    /// Arrow keys navigate the grid; holding Shift extends the selection as a
    /// range. When the viewer is open it owns the arrow keys, so the grid
    /// ignores them.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !model.isViewerPresented else { return .ignored }
        // While the search field is focused, defer every key to it so typing —
        // and native text editing like ⌘A (select all text) — isn't hijacked
        // by the grid's shortcuts.
        guard !searchFocused else { return .ignored }

        // Cmd+A selects everything in the grid.
        if press.modifiers.contains(.command), press.key == KeyEquivalent("a") {
            model.selectAll()
            return .handled
        }

        // Note: ⌘⌫ "Move to Trash" is handled by the menu-bar command (see
        // LoupeApp), which AppKit routes to the key window through the
        // responder chain. We intentionally don't handle it here so there's a
        // single, unambiguous owner of the shortcut.

        // F (no modifiers) flags/unflags the current selection.
        if press.modifiers.isEmpty, press.key == KeyEquivalent("f") {
            model.toggleFlag()
            return .handled
        }

        // Y (no modifiers) opens the tag-input overlay for the selection.
        // Handled here (not only via the hidden window-level shortcut) so it
        // works regardless of focus state — including right after building a
        // multi-selection, where the window shortcut didn't always fire.
        if press.modifiers.isEmpty, press.key == KeyEquivalent("y") {
            model.beginTagging()
            return .handled
        }

        // O / U step the preview sidebar's video forward / backward (only
        // meaningful while the preview sidebar is showing a video). Handled
        // before the navigation mapping so they don't fall through to it.
        if press.modifiers.isEmpty, press.key == KeyEquivalent("o") {
            if model.seekPreviewVideo(by: Self.previewSeekSeconds) { return .handled }
            return .ignored
        }
        if press.modifiers.isEmpty, press.key == KeyEquivalent("u") {
            if model.seekPreviewVideo(by: -Self.previewSeekSeconds) { return .handled }
            return .ignored
        }

        // I/J/K/L mirror the arrow keys (I=up, J=left, K=down, L=right) so the
        // selection can be driven from the home row without reaching for the
        // arrows.
        let direction: BrowserModel.MoveDirection
        switch press.key {
        case .leftArrow,  KeyEquivalent("j"): direction = .left
        case .rightArrow, KeyEquivalent("l"): direction = .right
        case .upArrow,    KeyEquivalent("i"): direction = .up
        case .downArrow,  KeyEquivalent("k"): direction = .down
        default:          return .ignored
        }

        model.selectFirstIfNeeded()
        let extend = press.modifiers.contains(.shift)
        // Use the live, rendered column count so Up/Down jump exactly one row
        // even if an external resize changed the grid without the width-based
        // observer catching up.
        model.moveSelection(direction, columns: liveColumnCount, extend: extend)
        return .handled
    }

    /// Right-click menu for a grid item. Actions apply to the whole selection
    /// when the clicked item is part of it, otherwise just to that item.
    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        let count = model.actionURLs(preferring: item).count
        let suffix = count > 1 ? " (\(count) items)" : ""

        Button("Open in Viewer") {
            if !model.selectedItems.contains(item.id) { model.selectOnly(item.id) }
            model.isViewerPresented = true
        }

        Divider()

        // Flag label reflects whether the acted-on target(s) are flagged.
        let targetsFlagged = flagStateForMenu(item)
        Button(flagMenuTitle(targetsFlagged, suffix: suffix),
               systemImage: targetsFlagged == .allFlagged ? "flag.slash" : "flag") {
            model.toggleFlag(item)
        }

        // Hide label mirrors the flag item: shows "Unhide" when every target is
        // already hidden, else "Hide".
        let targetsHidden = hiddenStateForMenu(item)
        Button(targetsHidden ? "Unhide\(suffix)" : "Hide\(suffix)",
               systemImage: targetsHidden ? "eye" : "eye.slash") {
            model.toggleHidden(item)
        }

        colorTagMenu(for: item, suffix: suffix)

        if classifyTargetCount(for: item) > 0 {
            Button("Classify with AI\(suffix)", systemImage: "sparkles") {
                model.classifySelection(item)
            }
            .disabled(model.isClassifying)
            Button("Find Faces\(suffix)", systemImage: "person.crop.circle") {
                model.recognizeFacesInSelection(item)
            }
            .disabled(model.isClassifying)

            // Manual corrections: move file(s) between categories/people.
            ClassificationEditMenu(model: model, item: item)
        }

        Divider()

        Button("Copy\(suffix)", systemImage: "doc.on.doc") {
            model.copyToClipboard(item)
        }
        // Copy the picture itself (pixels) at a chosen size, optionally with
        // metadata stripped. Only offered when the target(s) include an image.
        if model.imageURLs(preferring: item).isEmpty == false {
            Menu("Copy Image As") {
                Picker("Format", selection: $model.imageCopyFormat) {
                    ForEach(ImageCopyFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.inline)
                Toggle("Remove EXIF / Metadata", isOn: $model.imageCopyStripsMetadata)
                    .disabled(!model.imageCopyFormat.canCarryMetadata)
                Divider()
                ForEach(ImageCopyScale.allCases, id: \.self) { scale in
                    Button(scale.displayName) {
                        model.copyImageToClipboard(
                            item,
                            scale: scale,
                            format: model.imageCopyFormat,
                            stripMetadata: model.imageCopyStripsMetadata
                        )
                    }
                }
            }
            // Export the picture(s) to a chosen folder, re-encoded at a picked
            // resolution and format (optionally without EXIF).
            Menu("Export Image As") {
                Picker("Format", selection: $model.exportFormat) {
                    ForEach(ImageCopyFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.inline)
                Picker("Resolution", selection: $model.exportScale) {
                    ForEach(ImageCopyScale.allCases, id: \.self) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.inline)
                if model.exportFormat == .jpeg {
                    Picker("Quality", selection: $model.exportJPEGQuality) {
                        ForEach(LoupeCommands.jpegQualityPresets, id: \.self) { q in
                            Text("\(q)").tag(q)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Toggle("Remove EXIF / Metadata", isOn: $model.exportStripsMetadata)
                    .disabled(!model.exportFormat.canCarryMetadata)
                Divider()
                Button("Export to Folder…") {
                    model.exportImagesToChosenFolder(item)
                }
            }
            .disabled(model.isExportingImages)
        }
        Button("Open with Default App\(suffix)") {
            model.openInDefaultApp(item)
        }
        Button("Reveal in Finder\(suffix)") {
            model.revealInFinder(item)
        }

        Divider()

        Button("Move to Trash\(suffix)", systemImage: "trash", role: .destructive) {
            Task { await model.moveToTrash(item) }
        }
        // No .keyboardShortcut here: a shortcut on a context-menu button is
        // registered globally for every item while the grid is visible, so
        // dozens of buttons would claim ⌘⌫ at once and fight the single global
        // handler in ContentView — the cause of the key working only sometimes.
        // The global hotkey covers ⌘⌫; the menu still shows it as a hint.
    }

    /// How many image items a classify action would act on for `item`: the
    /// image(s) in the selection when the clicked item is part of it, else just
    /// the clicked item if it's an image. Zero hides the menu entry.
    private func classifyTargetCount(for item: MediaItem) -> Int {
        if model.selectedItems.contains(item.id) {
            return model.selectedMediaItems.filter { $0.kind == .image }.count
        }
        return item.kind == .image ? 1 : 0
    }

    private enum FlagState { case allFlagged, someOrNone }

    /// Whether every target of a flag action is already flagged, to choose
    /// between "Flag" and "Unflag" in the menu.
    private func flagStateForMenu(_ item: MediaItem) -> FlagState {
        let targets: [MediaItem.ID]
        if model.selectedItems.contains(item.id) {
            targets = Array(model.selectedItems)
        } else {
            targets = [item.id]
        }
        let allFlagged = !targets.isEmpty && targets.allSatisfy { model.isFlagged($0) }
        return allFlagged ? .allFlagged : .someOrNone
    }

    /// Whether every target of a hide action is already hidden, to choose
    /// between "Hide" and "Unhide" in the menu.
    private func hiddenStateForMenu(_ item: MediaItem) -> Bool {
        let targets: [MediaItem.ID]
        if model.selectedItems.contains(item.id) {
            targets = Array(model.selectedItems)
        } else {
            targets = [item.id]
        }
        return !targets.isEmpty && targets.allSatisfy { model.isHidden($0) }
    }

    private func flagMenuTitle(_ state: FlagState, suffix: String) -> String {
        state == .allFlagged ? "Unflag\(suffix)" : "Flag for Later\(suffix)"
    }

    /// Right-click "Color Tag" submenu. Mirrors the flag item: acts on the
    /// whole selection when the clicked item is part of it, else just that
    /// item. No keyboard shortcuts here (the global ⌃1–⌃5 own those).
    @ViewBuilder
    private func colorTagMenu(for item: MediaItem, suffix: String) -> some View {
        Menu("Color Tag\(suffix)") {
            ForEach(ColorTag.allInHotkeyOrder, id: \.self) { tag in
                Button(tag.displayName, systemImage: tag.symbol) {
                    model.toggleColorTag(tag, item: item)
                }
            }
            Divider()
            Button("Remove Tag") { model.clearColorTag(item: item) }
        }
    }
}

/// Sizes the grid content: normally it fills the available width; while a
/// `frozenWidth` is set (during a preview-sidebar resize) it's pinned to that
/// exact width and leading-aligned, so the adaptive `LazyVGrid` keeps its
/// column layout instead of re-flowing as the panel squeezes the grid.
private struct GridContentWidth: ViewModifier {
    let frozenWidth: CGFloat?
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        if let frozenWidth {
            content
                .frame(width: frozenWidth, alignment: .topLeading)
                .frame(minHeight: minHeight, alignment: .topLeading)
        } else {
            content.frame(maxWidth: .infinity, minHeight: minHeight, alignment: .top)
        }
    }
}

/// Identity for the background "warm the rest of the displayed set" task, so
/// `.task(id:)` restarts (and cancels the prior pass) whenever the displayed
/// set or the thumbnail-generation options change. `revision` captures set
/// membership and order (it's bumped on every display change); the thumbnail
/// method/position/size are included so changing them re-warms under the new
/// key the cache is stored under. `isScanning` is included so the pass pauses
/// while a scan holds the disk and resumes (re-running the task) once it ends.
private struct WarmAllKey: Equatable {
    let revision: Int
    let method: ThumbnailMethod
    let videoPosition: VideoThumbnailPosition
    let size: Double
    let isScanning: Bool
}
