import Foundation
import NaturalLanguage

/// Derives "OCR tags" — common words in recognized text — so they can be
/// listed in the sidebar and used as filters like color or text tags.
enum OCRTags {
    /// Shortest word kept as a tag.
    static let minLength = 4
    /// A word must appear in at least this many items to be a tag.
    static let minItems = 2
    /// Maximum tags shown in the sidebar.
    static let maxTags = 40

    /// Distinct lowercase alphabetic words in `text` worth tagging: at least
    /// `minLength` letters and not a common English stop word.
    static func words(in text: String) -> Set<String> {
        var out: Set<String> = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let w = text[range].lowercased()
            if w.count >= minLength, w.allSatisfy(\.isLetter), !stopWords.contains(w) {
                out.insert(w)
            }
            return true
        }
        return out
    }

    /// Ranks words by item count (desc, then alphabetical), dropping rare and
    /// dismissed ones, capped at `maxTags`.
    static func rank(_ counts: [String: Int], dismissed: Set<String>) -> [String] {
        counts
            .filter { $0.value >= minItems && !dismissed.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxTags)
            .map(\.key)
    }

    private static let stopWords: Set<String> = [
        "that", "this", "with", "from", "have", "will", "your", "they", "their",
        "there", "been", "were", "what", "when", "which", "would", "could",
        "should", "about", "into", "than", "then", "them", "these", "those",
        "more", "some", "such", "only", "also", "other", "over", "just", "very",
        "here", "where", "while", "because", "being", "does", "each", "most",
        "much", "many", "must", "said", "same", "like", "make", "made", "once",
        "both", "after", "before", "again", "under", "until", "upon", "ours",
        "yours", "its", "shall", "might", "still", "even", "however",
    ]
}
