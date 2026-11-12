import SwiftUI
import AppKit

/// Sheet for finding and removing duplicate files. Shows each group of exact or
/// similar files side by side with the suggested keeper preselected; the user
/// can flip any file between Keep and Remove, then move the marked ones to the
/// Trash (recoverable). A group always keeps at least one file.
struct DuplicatesView: View {
    @Bindable var model: BrowserModel
    /// Files marked for removal.
    @State private var marked: Set<URL> = []
    @State private var confirmTrash = false
    @State private var isTrashing = false
    /// The file shown in the large preview, if any.
    @State private var previewing: PreviewTarget?

    private struct PreviewTarget: Equatable {
        let groupID: Int
        let url: URL
    }

    private static let tileSize: CGFloat = 150

    private var markedBytes: Int64 {
        model.duplicateGroups.flatMap(\.items)
            .filter { marked.contains($0.url) }
            .reduce(Int64(0)) { $0 + $1.fileSize }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
        .overlay { previewOverlay }
        .onAppear { resetMarks() }
        .onChange(of: model.duplicateRunID) { resetMarks() }
        .onDisappear { model.cancelDuplicateSearch() }
        .confirmationDialog(
            "Move \(marked.count) \(marked.count == 1 ? "file" : "files") to the Trash?",
            isPresented: $confirmTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trashMarked() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(byteString(markedBytes)). You can restore them from the Trash.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Find Duplicates").font(.headline)
                Text(scopeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Match", selection: $model.duplicateSensitivity) {
                ForEach(DuplicateSensitivity.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 260)
            .disabled(model.isFindingDuplicates)
            .onChange(of: model.duplicateSensitivity) { model.findDuplicates() }
            Button(model.hasSearchedDuplicates ? "Search Again" : "Search") {
                model.findDuplicates()
            }
            .disabled(model.isFindingDuplicates)
        }
        .padding(10)
    }

    private var scopeText: String {
        let n = model.duplicateScanCount
        let files = "\(n) \(n == 1 ? "file" : "files")"
        return model.duplicateSearchIsSelection && !model.hasSearchedDuplicates
            ? "Searching \(files) in the selection"
            : "Searched \(files)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isFindingDuplicates {
            VStack(spacing: 10) {
                ProgressView(
                    value: Double(model.duplicateProgress),
                    total: Double(max(model.duplicateTotal, 1))
                )
                .frame(width: 280)
                Text("Comparing files… \(model.duplicateProgress) of \(model.duplicateTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancelDuplicateSearch() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasSearchedDuplicates {
            placeholder("Press Search to look for duplicates.")
        } else if model.duplicateGroups.isEmpty {
            placeholder("No duplicates found.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.duplicateGroups) { group in
                        groupView(group)
                    }
                }
                .padding(12)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupView(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    group.kind == .exact ? "Exact copies" : "Similar \(group.similarNoun)",
                    systemImage: group.kind == .exact ? "equal.circle" : "square.on.square"
                )
                .font(.subheadline.weight(.semibold))
                Text("\(group.items.count) files · \(byteString(group.reclaimableBytes)) reclaimable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(group.items) { item in
                        tile(item, in: group)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func tile(_ item: MediaItem, in group: DuplicateGroup) -> some View {
        let isMarked = marked.contains(item.url)
        return VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                DuplicateThumbnail(item: item, size: Self.tileSize)
                    .frame(width: Self.tileSize, height: Self.tileSize)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(isMarked ? 0.45 : 1)
                Text(isMarked ? "Remove" : "Keep")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isMarked ? Color.red : Color.green, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
                Button {
                    previewing = PreviewTarget(groupID: group.id, url: item.url)
                } label: {
                    Image(systemName: "eye.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Preview")
                .accessibilityLabel("Preview \(item.name)")
                .padding(6)
                .frame(width: Self.tileSize, height: Self.tileSize, alignment: .bottomTrailing)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isMarked ? Color.red.opacity(0.7) : Color.green.opacity(0.7), lineWidth: 2)
            )
            Text(item.name).font(.caption).lineLimit(1)
            Text(detail(for: item, in: group))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.parentDirectory.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(width: Self.tileSize)
        .contentShape(Rectangle())
        .onTapGesture { toggle(item, in: group) }
        .contextMenu {
            Button("Preview") { previewing = PreviewTarget(groupID: group.id, url: item.url) }
            Button("Keep Only This One") { keepOnly(item, in: group) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
        .help(item.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(isMarked ? "marked for removal" : "kept")")
        .accessibilityHint("Toggles between keep and remove")
        .accessibilityAddTraits(.isButton)
    }

    private func detail(for item: MediaItem, in group: DuplicateGroup) -> String {
        var parts: [String] = []
        if let size = group.pixelSizes[item.url] {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        parts.append(byteString(item.fileSize))
        return parts.joined(separator: " · ")
    }

    // MARK: Preview

    @ViewBuilder
    private var previewOverlay: some View {
        if let target = previewing,
           let group = model.duplicateGroups.first(where: { $0.id == target.groupID }),
           let index = group.items.firstIndex(where: { $0.url == target.url }) {
            let item = group.items[index]
            let isMarked = marked.contains(item.url)
            ZStack {
                Color.black.opacity(0.45)
                    .onTapGesture { previewing = nil }
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline).lineLimit(1)
                            Text("\(detail(for: item, in: group)) · \(item.url.deletingLastPathComponent().path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(index + 1) of \(group.items.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    Divider()
                    Group {
                        switch item.kind {
                        case .video, .audio:
                            // Quick Look's embedded player doesn't play inside
                            // a sheet, so use the app's own player (AVFoundation
                            // or mpv for mkv/webm), same as the main preview.
                            VideoPlayerView(url: item.url)
                        default:
                            QuickLookView(url: item.url)
                        }
                    }
                    .id(item.url)
                    Divider()
                    HStack {
                        Button("Previous", systemImage: "chevron.left") {
                            step(-1, in: group, from: index)
                        }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(group.items.count < 2)
                        Button("Next", systemImage: "chevron.right") {
                            step(1, in: group, from: index)
                        }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(group.items.count < 2)
                        Spacer()
                        Button(isMarked ? "Keep This File" : "Mark for Removal") {
                            toggle(item, in: group)
                        }
                        Button("Close") { previewing = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(10)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
                .padding(28)
            }
            .accessibilityAddTraits(.isModal)
        }
    }

    /// Moves the preview to the neighboring file in the group, wrapping around.
    private func step(_ delta: Int, in group: DuplicateGroup, from index: Int) {
        let count = group.items.count
        guard count > 1 else { return }
        let next = (index + delta + count) % count
        previewing = PreviewTarget(groupID: group.id, url: group.items[next].url)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(marked.isEmpty
                 ? "Nothing marked for removal"
                 : "\(marked.count) marked · \(byteString(markedBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset Suggestions") { resetMarks() }
                .disabled(model.duplicateGroups.isEmpty)
            Button("Done") { model.showDuplicatesPanel = false }
                // Esc closes the preview first, so Done only owns it otherwise.
                .keyboardShortcut(previewing == nil ? .cancelAction : nil)
            Button("Move \(marked.count) to Trash…", role: .destructive) { confirmTrash = true }
                .disabled(marked.isEmpty || isTrashing || model.isFindingDuplicates)
        }
        .padding(10)
    }

    // MARK: Actions

    /// Marks everything except each group's suggested keeper.
    private func resetMarks() {
        marked = Set(model.duplicateGroups.flatMap { $0.items.dropFirst().map(\.url) })
    }

    /// Flips a file between keep and remove, but never marks a group's last
    /// remaining kept file.
    private func toggle(_ item: MediaItem, in group: DuplicateGroup) {
        if marked.contains(item.url) {
            marked.remove(item.url)
        } else {
            let keptCount = group.items.filter { !marked.contains($0.url) }.count
            guard keptCount > 1 else { return }
            marked.insert(item.url)
        }
    }

    private func keepOnly(_ item: MediaItem, in group: DuplicateGroup) {
        for other in group.items {
            if other.url == item.url { marked.remove(other.url) } else { marked.insert(other.url) }
        }
    }

    private func trashMarked() {
        let urls = Array(marked)
        isTrashing = true
        Task {
            await model.trashDuplicates(urls)
            // Remaining marks are the ones that failed to trash; drop any whose
            // file is gone so the count stays honest.
            let present = Set(model.duplicateGroups.flatMap { $0.items.map(\.url) })
            marked.formIntersection(present)
            if let target = previewing, !present.contains(target.url) { previewing = nil }
            isTrashing = false
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A square thumbnail loaded through the shared provider.
private struct DuplicateThumbnail: View {
    let item: MediaItem
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: item.kind.fallbackSymbol)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.url) {
            image = await ThumbnailProvider.shared.thumbnail(
                for: item.url,
                size: CGSize(width: size, height: size),
                scale: NSScreen.main?.backingScaleFactor ?? 2
            )
        }
        .accessibilityHidden(true)
    }
}
