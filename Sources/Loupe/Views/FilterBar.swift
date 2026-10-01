import SwiftUI

/// A single filter chip. A plain click replaces the filter with this chip;
/// Shift- or Command-click adds/removes it (multi-select). `action` receives
/// `additive = true` when a modifier key was held.
struct FilterChip: View {
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil
    let isSelected: Bool
    let action: (_ additive: Bool) -> Void

    var body: some View {
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
        .contentShape(Capsule())
        // AppKit-level click so we can read the Shift/Command modifiers.
        .onClick(
            single: { mods in action(mods.shift || mods.command) },
            double: { mods in action(mods.shift || mods.command) }
        )
        .help("Click to filter by this; Shift- or ⌘-click to select multiple")
    }
}

/// A horizontally scrolling bar of type and extension filter chips. Shown above
/// the grid; hidden when the current scope has no items to filter.
struct FilterBar: View {
    @Bindable var model: BrowserModel

    var body: some View {
        let kinds = model.availableKindChips
        let exts = model.availableExtensionChips

        // Only worth showing when there's more than one thing to distinguish —
        // but always keep the bar up while a filter is active, otherwise
        // changing to a folder whose scope has just one kind would hide the bar
        // (and its Clear button) with the filter still silently applied.
        if kinds.count > 1 || exts.count > 1 || model.hasActiveChipFilters {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(kinds) { chip in
                        FilterChip(
                            title: chip.kind.displayName,
                            systemImage: chip.kind.fallbackSymbol,
                            count: chip.count,
                            isSelected: model.selectedKinds.contains(chip.kind)
                        ) { additive in
                            model.selectKind(chip.kind, additive: additive)
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
                        ) { additive in
                            model.selectExtension(chip.ext, additive: additive)
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
