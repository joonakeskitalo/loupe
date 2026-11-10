import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sheet for browsing OCR'd text: an "All Text" entry that shows everything in
/// one place, plus one entry per image for browsing text image by image.
struct OCRTextView: View {
    @Bindable var model: BrowserModel

    private enum Entry: Hashable {
        case all
        case item(URL)
    }

    @State private var selection: Entry = .all
    @State private var filter = ""

    private var items: [MediaItem] {
        let base = model.ocrItems
        guard !filter.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || (model.ocrText[$0.id] ?? "").localizedCaseInsensitiveContains(filter)
        }
    }

    private var combinedText: String {
        items.map { "=== \($0.name) ===\n\(model.ocrText[$0.id] ?? "")" }
            .joined(separator: "\n\n")
    }

    private var shownText: String {
        switch selection {
        case .all: return combinedText
        case .item(let url): return model.ocrText[url] ?? ""
        }
    }

    private var shownTitle: String {
        switch selection {
        case .all: return "All Text (\(items.count) images)"
        case .item(let url): return url.lastPathComponent
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                list
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                detail
                    .frame(minWidth: 320)
            }
            Divider()
            HStack {
                let scanned = model.ocrText.count
                Text("\(model.ocrTextCount) of \(scanned) scanned images contain text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", role: .destructive) {
                    model.clearOCRText()
                    model.showOCRPanel = false
                }
                Button("Done") { model.showOCRPanel = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            // Land on the selected image's text when there is exactly one.
            if model.selectedItems.count == 1, let id = model.selectedItems.first,
               !(model.ocrText[id] ?? "").isEmpty {
                selection = .item(id)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Filter text or filename", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: $selection) {
                Label("All Text", systemImage: "text.alignleft")
                    .tag(Entry.all)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1)
                        Text(snippet(model.ocrText[item.id] ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .tag(Entry.item(item.id))
                }
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HStack {
                Text(shownTitle).font(.headline).lineLimit(1)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shownText, forType: .string)
                }
                .disabled(shownText.isEmpty)
                Button("Save…", systemImage: "square.and.arrow.down") { save() }
                    .disabled(shownText.isEmpty)
            }
            .padding(10)
            Divider()
            ScrollView {
                SelectableTextView(text: shownText.isEmpty ? "No text found." : shownText,
                                   font: .preferredFont(forTextStyle: .body))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private func snippet(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        switch selection {
        case .all: panel.nameFieldStringValue = "Recognized Text.txt"
        case .item(let url):
            panel.nameFieldStringValue =
                url.deletingPathExtension().lastPathComponent + ".txt"
        }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? shownText.write(to: dest, atomically: true, encoding: .utf8)
    }
}
