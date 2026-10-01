import SwiftUI

/// A thin status bar pinned to the bottom of the detail view showing the full
/// path of the primary selected file as a Finder-style breadcrumb. When nothing
/// is selected it shows a muted placeholder so the bar's height stays stable.
struct PathBar: View {
    var model: BrowserModel

    var body: some View {
        HStack(spacing: 0) {
            if let url = model.primarySelectedItem?.url {
                breadcrumb(for: url)
            } else {
                Text("No selection")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // Let the full path be read even when it's truncated on screen.
        .help(model.primarySelectedItem?.url.path ?? "")
    }

    /// Renders the path's components separated by chevrons, with a leading
    /// folder icon. The file name (last component) is emphasized.
    @ViewBuilder
    private func breadcrumb(for url: URL) -> some View {
        let components = pathComponents(of: url)
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(name)
                    .font(.callout)
                    .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The on-disk path split into display components, dropping the leading
    /// empty component produced by the root "/".
    private func pathComponents(of url: URL) -> [String] {
        url.standardizedFileURL.pathComponents.filter { $0 != "/" }
    }
}
