import SwiftUI

/// Previews a text or Markdown file. Markdown is rendered block-by-block with
/// real structure (headings, lists, code blocks, quotes); plain text and source
/// files are shown monospaced. Content is loaded off the main thread and the
/// view scrolls for long documents.
struct TextDocumentView: View {
    let url: URL
    let renderMarkdown: Bool

    @State private var raw: String = ""
    @State private var blocks: [MarkdownBlock] = []
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView(
                    "Can't Open File",
                    systemImage: "doc.questionmark",
                    description: Text(loadError)
                )
            } else {
                ScrollView {
                    content
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                        .textSelection(.enabled)
                }
            }
        }
        .background(Color(white: 0.97))
        .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if renderMarkdown {
            MarkdownView(blocks: blocks)
        } else {
            Text(raw)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.black)
                .lineSpacing(2)
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        let fileURL = url
        let wantsMarkdown = renderMarkdown

        let result: Result<(String, [MarkdownBlock]), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: fileURL)
                // Decode as UTF-8, falling back to Latin-1 so arbitrary text
                // files still show something rather than failing outright.
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                let parsed = wantsMarkdown ? MarkdownParser.parse(text) : []
                return .success((text, parsed))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let (text, parsed)):
            raw = text
            blocks = parsed
        case .failure(let error):
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
