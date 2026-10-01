import SwiftUI

/// A single toggleable filter chip: label, optional count, selected state.
struct FilterChip: View {
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                }
                Text(title)
                    .font(.callout)
                if let count {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(
                    isSelected ? Color.clear : Color.secondary.opacity(0.25),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }
}

/// A horizontally scrolling bar of type and extension filter chips. Shown above
/// the grid; hidden when the current scope has no items to filter.
struct FilterBar: View {
    @Bindable var model: BrowserModel

    var body: some View {
        let kinds = model.availableKindChips
        let exts = model.availableExtensionChips

        // Only worth showing when there's more than one thing to distinguish.
        if kinds.count > 1 || exts.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(kinds) { chip in
                        FilterChip(
                            title: chip.kind.displayName,
                            systemImage: chip.kind.fallbackSymbol,
                            count: chip.count,
                            isSelected: model.selectedKinds.contains(chip.kind)
                        ) {
                            model.toggleKind(chip.kind)
                        }
                    }

                    if !kinds.isEmpty && !exts.isEmpty {
                        Divider().frame(height: 20)
                    }

                    ForEach(exts) { chip in
                        FilterChip(
                            title: ".\(chip.ext)",
                            count: chip.count,
                            isSelected: model.selectedExtensions.contains(chip.ext)
                        ) {
                            model.toggleExtension(chip.ext)
                        }
                    }

                    if model.hasActiveChipFilters {
                        Divider().frame(height: 20)
                        Button {
                            model.clearChipFilters()
                        } label: {
                            Label("Clear", systemImage: "xmark.circle.fill")
                                .font(.callout)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear type and extension filters")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }
}
