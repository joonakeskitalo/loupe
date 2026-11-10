import Foundation
import CoreImage
import Vision

/// On-device OCR built on Vision's `RecognizeTextRequest` (macOS 15+). Nothing
/// leaves the machine. Stateless: the browser model owns the results, so this
/// is just a namespace for the slow perception work.
enum TextRecognizer {
    /// Recognizes text in the image at `url` and returns it as plain text, one
    /// recognized line per line, in Vision's reading order. Returns an empty
    /// string when the file can't be decoded or contains no text.
    ///
    /// Runs on a detached utility task so many images can be processed
    /// concurrently without blocking the main actor.
    static func recognizeText(in url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let image = CIImage(contentsOf: url,
                                      options: [.applyOrientationProperty: true]) else {
                return ""
            }
            do {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let observations = try await request.perform(on: image)
                return observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return ""
            }
        }.value
    }
}
