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
        }
        .task(id: metadataNeedsProbe ? item.id : nil) { await probeMetadata() }
        .task(id: item.id) { await loadThumbnail() }
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
                    TextField(
                        "px",
                        value: $model.exportCustomLongEdge,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    Text("px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    TextField(
                        "CQ",
                        value: $model.exportVideoConstantQuality,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 56)
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

            if model.isExportingVideo {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: perFileProgress)
                        .progressViewStyle(.linear)
                    Text("Transcoding \(min(model.videoExportCompleted + 1, model.videoExportTotal))/\(model.videoExportTotal)…")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else {
                Button {
                    model.exportVideosToChosenFolder(item)
                } label: {
                    Label("Export to Folder…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .padding(.top, 2)

                if model.canQuickExportVideo(item), let dir = model.lastExportDirectory {
                    Button {
                        model.quickExportVideo(item)
                    } label: {
                        Label("Quick Export to \(dir.lastPathComponent)", systemImage: "bolt")
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .controlSize(.small)
                    .help("Transcode again to \(dir.path) without choosing a folder.")
                }
            }
        }
    }

    /// Combined progress across the batch: completed files plus the current
    /// file's fraction, over the total count.
    private var perFileProgress: Double {
        guard model.videoExportTotal > 0 else { return 0 }
        let done = Double(model.videoExportCompleted) + model.videoExportFraction
        return min(1.0, done / Double(model.videoExportTotal))
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
