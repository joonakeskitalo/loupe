import SwiftUI

/// A right-hand sidebar showing information and metadata about the current
/// selection. For a single selected item it lists its name, kind, size, pixel
/// dimensions (and video codec), dates, color tag / flag status, and full
/// path. For a multi-selection it summarizes the count and combined size.
///
/// Pixel dimensions / codec come from the same lazy metadata pipeline the list
/// view uses (`MediaMetadataCache` for an already-resolved value, falling back
/// to a `VideoMetadataProvider` probe), so opening the sidebar on an image or
/// video resolves its dimensions without decoding pixels.
struct ItemInfoSidebar: View {
    var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxHeight: .infinity)
            // The transcode queue is pinned to the bottom, independent of the
            // current selection, so switching videos never misattributes an
            // in-flight export. Shown only while the queue has entries.
            if !model.videoExportQueue.isEmpty {
                Divider()
                VideoExportQueueView(model: model)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .leading) { Divider() }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Info")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        let selected = model.selectedMediaItems
        if selected.count > 1 {
            multiSelection(selected)
        } else if let item = model.primarySelectedItem {
            SingleItemInfo(model: model, item: item)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No selection")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func multiSelection(_ items: [MediaItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                thumbnailStack(items)

                InfoSection(title: "Selection") {
                    InfoRow(label: "Items", value: "\(items.count)")
                    InfoRow(
                        label: "Total Size",
                        value: ByteCountFormatter.string(
                            fromByteCount: model.selectedItemsByteCount, countStyle: .file
                        )
                    )
                    ForEach(kindBreakdown(items), id: \.0) { kind, count in
                        InfoRow(label: kind.displayName, value: "\(count)")
                    }
                }

                RenameSection(model: model, item: nil)

                if items.contains(where: { $0.kind == .image }) {
                    ExportSection(model: model, item: nil)
                }
                if items.contains(where: { $0.kind == .video }) {
                    VideoExportSection(model: model, item: nil)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A small stacked thumbnail motif for a multi-selection, hinting at how
    /// many items are selected without rendering a full gallery.
    @ViewBuilder
    private func thumbnailStack(_ items: [MediaItem]) -> some View {
        ZStack {
            ForEach(Array(items.prefix(3).enumerated().reversed()), id: \.element.id) { index, item in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        Image(systemName: item.kind.fallbackSymbol)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 120, height: 120)
                    .offset(x: CGFloat(index) * 10, y: CGFloat(index) * 10)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    /// Counts of each media kind in the selection, in a stable order, omitting
    /// kinds not present.
    private func kindBreakdown(_ items: [MediaItem]) -> [(MediaKind, Int)] {
        var counts: [MediaKind: Int] = [:]
        for item in items { counts[item.kind, default: 0] += 1 }
        let order: [MediaKind] = [.image, .video, .pdf, .audio, .markdown, .text, .other]
        return order.compactMap { kind in
            guard let c = counts[kind], c > 0 else { return nil }
            return (kind, c)
        }
    }
}

/// The single-item detail body. Split into its own view so it can own the
/// metadata-probe `@State` and task lifecycle keyed to the item.
private struct SingleItemInfo: View {
    var model: BrowserModel
    let item: MediaItem

    @State private var metadata: MediaMetadata = .empty
    @State private var thumbnail: NSImage?
    @State private var exif: ImageEXIF = .empty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview

                InfoSection(title: "General") {
                    InfoRow(label: "Name", value: item.name)
                    InfoRow(label: "Kind", value: kindLabel)
                    InfoRow(
                        label: "Size",
                        value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
                    )
                    if let dimensions = metadata.pixelSize?.displayString {
                        InfoRow(label: "Dimensions", value: dimensions)
                    }
                    if item.kind == .video, let duration = metadata.duration {
                        InfoRow(label: "Length", value: durationString(duration))
                    }
                    if item.kind == .video, let codec = metadata.codec {
                        InfoRow(label: "Codec", value: codec.uppercased())
                    }
                }

                InfoSection(title: "Dates") {
                    InfoRow(label: "Created", value: dateString(item.creationDate))
                    InfoRow(label: "Modified", value: dateString(item.modificationDate))
                }

                if item.kind == .image, exif.hasAny {
                    exifSection
                }

                if hasAnnotations {
                    InfoSection(title: "Tags") {
                        if model.isFlagged(item.id) {
                            InfoRow(label: "Flagged", value: "Yes")
                        }
                        if let tag = model.colorTag(item.id) {
                            HStack {
                                Text("Color")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                HStack(spacing: 5) {
                                    Image(systemName: tag.symbol)
                                        .foregroundStyle(tag.color)
                                    Text(tag.displayName)
                                }
                            }
                            .font(.callout)
                        }
                    }
                }

                InfoSection(title: "Location") {
                    Text(item.url.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reveal in Finder") { model.revealInFinder(item) }
                        .controlSize(.small)
                        .padding(.top, 2)
                }

                RenameSection(model: model, item: item)

                if item.kind == .image {
                    ExportSection(model: model, item: item)
                }
                if item.kind == .video {
                    VideoExportSection(model: model, item: item)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Resolve metadata the same way list rows do: read any cached value
        // synchronously, then probe only when it's an image/video and missing.
        .onChange(of: item.id, initial: true) { _, _ in
            metadata = MediaMetadataCache.cached(for: item.url) ?? .empty
            thumbnail = nil
            exif = .empty
        }
        .task(id: metadataNeedsProbe ? item.id : nil) { await probeMetadata() }
        .task(id: item.id) { await loadThumbnail() }
        .task(id: item.kind == .image ? item.id : nil) { await probeEXIF() }
    }

    /// Camera / shooting metadata, shown only for images that carry EXIF.
    @ViewBuilder
    private var exifSection: some View {
        InfoSection(title: "Camera") {
            if let date = exif.dateTaken {
                InfoRow(label: "Taken", value: dateString(date))
            }
            if let make = exif.cameraMake, let model = exif.cameraModel {
                // Many models already include the make (e.g. "Canon EOS R6");
                // avoid repeating it.
                let combined = model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
                InfoRow(label: "Camera", value: combined)
            } else if let model = exif.cameraModel {
                InfoRow(label: "Camera", value: model)
            } else if let make = exif.cameraMake {
                InfoRow(label: "Camera", value: make)
            }
            if let lens = exif.lens {
                InfoRow(label: "Lens", value: lens)
            }
            if let focal = exif.focalLength {
                let value = exif.focalLength35mm.map { "\(focal) (\($0) eq.)" } ?? focal
                InfoRow(label: "Focal Length", value: value)
            }
            if let aperture = exif.aperture {
                InfoRow(label: "Aperture", value: aperture)
            }
            if let shutter = exif.shutterSpeed {
                InfoRow(label: "Shutter", value: shutter)
            }
            if let iso = exif.iso {
                InfoRow(label: "ISO", value: iso)
            }
            if let bias = exif.exposureBias, bias != "+0.0 EV" {
                InfoRow(label: "Exposure", value: bias)
            }
            if let flash = exif.flashFired {
                InfoRow(label: "Flash", value: flash ? "Fired" : "Off")
            }
            if let colorSpace = exif.colorSpace {
                InfoRow(label: "Color", value: colorSpace)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                Image(systemName: item.kind.fallbackSymbol)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
    }

    private var kindLabel: String {
        // `displayName` is plural ("Images"); singularize the common case.
        let ext = item.url.pathExtension.uppercased()
        let base: String
        switch item.kind {
        case .image: base = "Image"
        case .video: base = "Video"
        case .pdf: base = "PDF"
        case .audio: base = "Audio"
        case .markdown: base = "Markdown"
        case .text: base = "Text"
        case .other: base = "File"
        }
        return ext.isEmpty ? base : "\(base) · \(ext)"
    }

    private var hasAnnotations: Bool {
        model.isFlagged(item.id) || model.colorTag(item.id) != nil
    }

    private var metadataNeedsProbe: Bool {
        guard item.kind == .video || item.kind == .image else { return false }
        return MediaMetadataCache.cached(for: item.url) == nil
    }

    private func probeMetadata() async {
        guard item.kind == .video || item.kind == .image else { return }
        metadata = await VideoMetadataProvider.shared.metadata(for: item.url, kind: item.kind)
    }

    private func probeEXIF() async {
        guard item.kind == .image else { return }
        let result = await ImageEXIFProvider.shared.exif(for: item.url)
        // Guard against a late result from a previously-selected image.
        if item.kind == .image { exif = result }
    }

    private func loadThumbnail() async {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: 240, height: 240)
        if let result = await ThumbnailProvider.shared.thumbnail(
            for: item.url, size: target, scale: scale,
            method: model.thumbnailMethod, videoPosition: model.videoThumbnailPosition
        ) {
            thumbnail = result
        }
    }

    private func dateString(_ date: Date) -> String {
        guard date != .distantPast else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Formats a clip length in seconds as H:MM:SS (dropping the hours field
    /// when under an hour), e.g. "3:07" or "1:02:45".
    private func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// Export controls for the current image selection, embedded in the sidebar.
/// Mirrors the "Export Images As" menu — format, resolution, and a
/// remove-metadata toggle — but inline, with a button that prompts for a
/// destination folder and runs the export. Shown only when the target contains
/// at least one image.
///
/// `item` scopes the export: `nil` exports the whole selection (multi-select
/// case); a specific item exports just that one (single-item case). While an
/// export is running the controls disable and a progress readout appears.
private struct ExportSection: View {
    @Bindable var model: BrowserModel
    var item: MediaItem?

    var body: some View {
        InfoSection(title: "Export Image") {
          // Extra vertical spacing between the export controls so they don't
          // crowd together.
          VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: $model.exportFormat) {
                ForEach(ImageCopyFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            Picker("Resolution", selection: $model.exportScale) {
                ForEach(ImageCopyScale.allCases, id: \.self) { scale in
                    Text(scale.displayName).tag(scale)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            // The preset is ignored when a custom long edge is in effect, so
            // dim it to make the override obvious.
            .disabled(model.exportUseCustomLongEdge)

            // Custom long-edge override: cap the longest edge to an exact pixel
            // width the user types. Never upscales a smaller source.
            Toggle("Custom Long Edge", isOn: $model.exportUseCustomLongEdge)
                .controlSize(.small)

            if model.exportUseCustomLongEdge {
                HStack(spacing: 6) {
                    // ↑/↓ adjust by 10 px (Shift = 100 px).
                    SteppableIntField(
                        value: $model.exportCustomLongEdge,
                        range: 1...100_000,
                        step: 10,
                        width: 90
                    )
                    Text("px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // JPEG compression quality (0–100). Only shown for JPEG — PNG is
            // lossless, so quality doesn't apply. A field + stepper (rather than
            // a slider) keeps the row free of the slider's track line.
            if model.exportFormat == .jpeg {
                HStack(spacing: 6) {
                    Text("Quality")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // ↑/↓ adjust by 1 (Shift = 10); the stepper nudges by 5.
                    SteppableIntField(
                        value: $model.exportJPEGQuality,
                        range: 0...100,
                        step: 1
                    )
                    Stepper(
                        "",
                        value: $model.exportJPEGQuality,
                        in: 0...100,
                        step: 5
                    )
                    .labelsHidden()
                    .controlSize(.small)
                    Spacer()
                }
            }

            // PNG has no EXIF container, so stripping is moot for it.
            Toggle("Remove EXIF / Metadata", isOn: $model.exportStripsMetadata)
                .controlSize(.small)
                .disabled(!model.exportFormat.canCarryMetadata)

            if model.isExportingImages {
                HStack(spacing: 6) {
                    ProgressView(value: Double(model.exportProgress),
                                 total: Double(max(1, model.exportTotal)))
                        .progressViewStyle(.linear)
                    Text("\(model.exportProgress)/\(model.exportTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else {
                Button {
                    model.exportImagesToChosenFolder(item)
                } label: {
                    Label("Export to Folder…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .padding(.top, 2)

                // Quick re-export to the last-used folder, no prompt. Only
                // enabled once a folder has been chosen this session.
                if model.canQuickExport(item), let dir = model.lastExportDirectory {
                    Button {
                        model.quickExport(item)
                    } label: {
                        Label("Quick Export to \(dir.lastPathComponent)",
                              systemImage: "bolt")
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .controlSize(.small)
                    .help("Export again to \(dir.path) without choosing a folder.")
                }
            }
          }
        }
    }
}

/// Export controls for the current video selection, embedded in the sidebar.
/// Mirrors `ExportSection` but for video: a resolution preset (1080p / 720p)
/// and buttons that transcode the selection to a chosen folder (audio copied,
/// video rescaled). Shown only when the target contains at least one video.
///
/// `item` scopes the export like `ExportSection`: `nil` exports the whole
/// selection, a specific item exports just that one.
private struct VideoExportSection: View {
    @Bindable var model: BrowserModel
    var item: MediaItem?

    var body: some View {
        InfoSection(title: "Export Video") {
            Picker("Resolution", selection: $model.exportVideoResolution) {
                ForEach(VideoTranscoder.Resolution.allCases, id: \.self) { res in
                    Text(res.displayName).tag(res)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            Picker("Codec", selection: $model.exportVideoCodec) {
                ForEach(VideoTranscoder.Codec.allCases, id: \.self) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            // Rate control: constant quality (fixed perceptual quality, varies
            // file size) vs. an automatic bitrate.
            Toggle("Constant Quality", isOn: $model.exportVideoUseConstantQuality)
                .controlSize(.small)

            if model.exportVideoUseConstantQuality {
                HStack(spacing: 6) {
                    Text("CQ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // ↑/↓ adjust by 1 (Shift = 10); the stepper nudges by 5.
                    SteppableIntField(
                        value: $model.exportVideoConstantQuality,
                        range: 0...100,
                        step: 1
                    )
                    Stepper(
                        "",
                        value: $model.exportVideoConstantQuality,
                        in: 0...100,
                        step: 5
                    )
                    .labelsHidden()
                    .controlSize(.small)
                    Spacer()
                }
                Text("0–100, higher is better quality and larger files.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(codecHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // The buttons always enqueue — transcodes run in the queue (shown
            // at the bottom of the sidebar), so you can keep adding videos
            // while others encode.
            Button {
                model.exportVideosToChosenFolder(item)
            } label: {
                Label(addLabel, systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .padding(.top, 2)

            if model.canQuickExportVideo(item), let dir = model.lastExportDirectory {
                Button {
                    model.quickExportVideo(item)
                } label: {
                    Label("Quick Add to \(dir.lastPathComponent)", systemImage: "bolt")
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .controlSize(.small)
                .help("Queue a transcode to \(dir.path) without choosing a folder.")
            }
        }
    }

    /// The primary button's label: "Add to Queue" when something is already
    /// transcoding/queued, else the plain "Export to Folder…".
    private var addLabel: String {
        model.hasPendingVideoExports ? "Add to Export Queue…" : "Export to Folder…"
    }

    /// A one-line description of the selected codec, so the user understands
    /// the compatibility/speed tradeoff. Rescaling + audio copy applies to both.
    private var codecHint: String {
        switch model.exportVideoCodec {
        case .h264:
            return "Rescales video, copies audio. MP4 / H.264 — widely compatible, software encode (slower)."
        case .hevcVideoToolbox:
            return "Rescales video, copies audio. MP4 / H.265 — hardware encode (much faster), smaller files."
        }
    }
}

/// The transcode queue, pinned to the bottom of the sidebar. Lists every
/// queued / in-progress / finished job with its source name and status, so the
/// user always sees exactly which video is being transcoded — independent of
/// whatever is currently selected. Scrolls when the queue is long.
private struct VideoExportQueueView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transcode Queue")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if model.hasPendingVideoExports {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Text(summary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.videoExportQueue) { job in
                        VideoExportQueueRow(job: job) {
                            model.removeVideoExportJob(job.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 160)

            HStack(spacing: 12) {
                if model.videoExportQueue.contains(where: { $0.status.isFinished }) {
                    Button("Clear Finished") { model.clearFinishedVideoExports() }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button("Remove All") { model.clearVideoExportQueue() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .help("Cancel any running transcode and clear the queue.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// "1 of 3" while draining, else a finished count.
    private var summary: String {
        let total = model.videoExportQueue.count
        let finished = model.videoExportQueue.filter { $0.status.isFinished }.count
        if model.hasPendingVideoExports {
            return "\(finished + 1) of \(total)"
        }
        return "\(finished)/\(total) done"
    }
}

/// A single row in the transcode queue: a status glyph (or spinner), the
/// source file name, an inline progress bar while it's encoding, and a
/// remove/cancel button (drops a queued or finished job, cancels an active one).
private struct VideoExportQueueRow: View {
    let job: BrowserModel.VideoExportJob
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                statusGlyph
                Text(job.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                // Every job can be removed: a queued/finished one is dropped,
                // an in-flight one is cancelled.
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(job.status.isActive ? "Cancel transcode" : "Remove from queue")
            }
            if case .transcoding(let fraction) = job.status {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch job.status {
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .transcoding:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// A numeric text field whose value can also be nudged with the Up/Down arrow
/// keys while it's focused (Up increments, Down decrements by `step`; Shift
/// makes a ×10 jump). The typed value is committed and clamped to `range` on
/// each change, and every adjustment stays within `range`.
///
/// Used for the export fields (quality, custom long edge, video CQ) so the user
/// can hold ↑/↓ to dial a value in instead of retyping it.
private struct SteppableIntField: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var width: CGFloat = 56

    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: width)
            // Clamp whatever is typed back into the valid range.
            .onChange(of: value) { _, newValue in
                let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                if clamped != newValue { value = clamped }
            }
            // Arrow keys adjust the value; Shift makes a coarse (×10) step.
            .onKeyPress(.upArrow) { adjust(by: +effectiveStep()); return .handled }
            .onKeyPress(.downArrow) { adjust(by: -effectiveStep()); return .handled }
    }

    private func effectiveStep() -> Int {
        NSEvent.modifierFlags.contains(.shift) ? step * 10 : step
    }

    private func adjust(by delta: Int) {
        value = min(max(value + delta, range.lowerBound), range.upperBound)
    }
}

/// A titled group of info rows with consistent spacing.
private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content
        }
    }
}

/// A single label/value row: muted label on the left, value on the right.
private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// Bulk-rename controls embedded in the info sidebar. Works for both a single
/// file and a multi-selection: it operates on whatever `BrowserModel` resolves
/// as the rename targets (`item` scopes a single-item panel; `nil` targets the
/// whole selection, matching the export sections' convention).
///
/// Each enabled component (prepend / append / number sequence / parent folder /
/// current date) composes into the new name, and a live preview shows the first
/// couple of results before anything touches disk. The number sequence follows
/// on-screen order so it lines up with what the user sees in the grid.
private struct RenameSection: View {
    @Bindable var model: BrowserModel
    var item: MediaItem?

    // The rename settings live on the model (per window/tab lifetime) so they
    // survive the section being torn down and rebuilt as the selection changes
    // — deselecting everything no longer resets them. `config` reads the model;
    // the controls bind through `$model.renameConfig`.
    private var config: BulkRenameConfig { model.renameConfig }
    @State private var isRenaming = false
    // Re-evaluated on each render so the date preview stays current; captured
    // once at apply time inside the model.
    private var previewDate: Date { Date() }

    var body: some View {
        InfoSection(title: "Bulk Rename") {
            VStack(alignment: .leading, spacing: 12) {
                prependAppend
                Divider()
                numberingControls
                Divider()
                parentFolderControls
                dateControls
                Divider()
                preview
                renameButton
            }
        }
    }

    // MARK: Prepend / append

    @ViewBuilder
    private var prependAppend: some View {
        labeledField("Prepend", text: $model.renameConfig.prepend, placeholder: "text before")
        labeledField("Append", text: $model.renameConfig.append, placeholder: "text after")
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    // MARK: Number sequence

    @ViewBuilder
    private var numberingControls: some View {
        Toggle("Number Sequence", isOn: $model.renameConfig.numbering)
            .controlSize(.small)

        if config.numbering {
            VStack(alignment: .leading, spacing: 6) {
                affixPicker(selection: $model.renameConfig.numberAffix)

                HStack(spacing: 6) {
                    stepperRow("Start", value: $model.renameConfig.numberStart, range: 0...1_000_000)
                }
                HStack(spacing: 6) {
                    stepperRow("Step", value: $model.renameConfig.numberStep, range: 1...1000)
                }
                HStack(spacing: 6) {
                    stepperRow("Digits", value: $model.renameConfig.numberPadding, range: 1...8)
                }
            }
            .padding(.leading, 4)
        }
    }

    private func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .onChange(of: value.wrappedValue) { _, newValue in
                    let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                    if clamped != newValue { value.wrappedValue = clamped }
                }
            Stepper("", value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
            Spacer()
        }
    }

    // MARK: Parent folder

    @ViewBuilder
    private var parentFolderControls: some View {
        Toggle("Parent Folder Name", isOn: $model.renameConfig.parentFolder)
            .controlSize(.small)
        if config.parentFolder {
            affixPicker(selection: $model.renameConfig.parentFolderAffix)
                .padding(.leading, 4)
        }
    }

    // MARK: Date

    @ViewBuilder
    private var dateControls: some View {
        Toggle("Current Date", isOn: $model.renameConfig.date)
            .controlSize(.small)
        if config.date {
            VStack(alignment: .leading, spacing: 6) {
                affixPicker(selection: $model.renameConfig.dateAffix)
                Picker("Format", selection: $model.renameConfig.dateFormat) {
                    ForEach(RenameDateFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            .padding(.leading, 4)
        }
    }

    private func affixPicker(selection: Binding<RenameAffix>) -> some View {
        Picker("Position", selection: selection) {
            ForEach(RenameAffix.allCases, id: \.self) { affix in
                Text(affix.displayName).tag(affix)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        let plans = model.renamePreview(using: config, item: item, now: previewDate)
        let changing = plans.filter(\.isChange)

        if !config.hasAnyComponent {
            Text("Add a component to preview new names.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if changing.isEmpty {
            Text("No names would change.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(changing.prefix(3)) { plan in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plan.originalName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(plan.newName)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if changing.count > 3 {
                    Text("+\(changing.count - 3) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Apply

    @ViewBuilder
    private var renameButton: some View {
        let changingCount = model.renamePreview(using: config, item: item, now: previewDate)
            .filter(\.isChange).count

        Button {
            isRenaming = true
            Task {
                await model.renameSelection(using: config, item: item)
                isRenaming = false
            }
        } label: {
            HStack {
                if isRenaming {
                    ProgressView().controlSize(.mini)
                }
                Text(buttonTitle(changingCount))
                    .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.small)
        .disabled(isRenaming || !config.hasAnyComponent || changingCount == 0 || !model.canRenameSelection)
        .padding(.top, 2)
    }

    private func buttonTitle(_ count: Int) -> String {
        guard count > 0 else { return "Rename" }
        return count == 1 ? "Rename 1 File" : "Rename \(count) Files"
    }
}
