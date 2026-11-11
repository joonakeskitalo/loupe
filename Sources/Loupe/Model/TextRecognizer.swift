import Foundation
import CoreImage
import ImageIO
import Vision

/// On-device OCR built on Vision's `RecognizeTextRequest` (macOS 15+). Nothing
/// leaves the machine. Stateless: the browser model owns the results, so this
/// is just a namespace for the slow perception work.
enum TextRecognizer {
    /// Longest edge, in pixels, that an image is decoded at for OCR. Running
    /// the accurate recognizer on full-resolution photos (often 12–50 MP) is
    /// slow and memory-hungry without improving results: text legible to a
    /// person is still legible at this size.
    private static let maxPixelSize = 3072

    /// Recognizes text in the image at `url` and returns it as plain text, one
    /// recognized line per line, in Vision's reading order. Returns an empty
    /// string when the file can't be decoded or contains no text.
    ///
    /// Runs on a detached utility task so many images can be processed
    /// concurrently without blocking the main actor.
    static func recognizeText(in url: URL) async -> String {
        await Task.detached(priority: .utility) {
            if Task.isCancelled { return "" }
            guard let cgImage = downsampledImage(at: url) else { return "" }
            if Task.isCancelled { return "" }
            do {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let observations = try await request.perform(on: cgImage)
                return observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return ""
            }
        }.value
    }

    /// Decodes the image capped at `maxPixelSize` on its long edge, with EXIF
    /// orientation applied. ImageIO decodes straight to the reduced size, so a
    /// huge source never has to be fully materialized in memory.
    private static func downsampledImage(at url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
