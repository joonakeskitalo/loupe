import SwiftUI

/// The main content area: a scrollable grid of thumbnails.
struct BrowserGridView: View {
    @Bindable var model: BrowserModel

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.thumbnailSize + 24), spacing: 12)]
    }

    var body: some View {
        let items = model.displayedItems
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Media Here",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(model.mode == .folders
                        ? "This folder has no previewable files."
                        : "The dropped folder contains no previewable files.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(items) { item in
                                ThumbnailView(
                                    item: item,
                                    size: model.thumbnailSize,
                                    isSelected: model.selectedItem == item.id
                                )
                                .id(item.id)
                                .onTapGesture(count: 2) {
                                    model.selectedItem = item.id
                                    model.isViewerPresented = true
                                }
                                .onTapGesture {
                                    model.selectedItem = item.id
                                }
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: model.selectedItem) { _, newValue in
                        if let newValue {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
}
