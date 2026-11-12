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

    /// Longest an image may take before it's abandoned. Vision or the decode
    /// (e.g. a file still downloading from iCloud or a stalled network volume)
    /// can hang indefinitely and neither is cancellable, which would otherwise
    /// leave the whole OCR pass stuck waiting on it.
    private static let timeout: Duration = .seconds(45)

    /// Recognizes text in the image at `url` and returns it as plain text, one
    /// recognized line per line, in Vision's reading order. Returns an empty
    /// string when the file can't be decoded or contains no text, and `nil`
    /// when the image timed out (so it isn't recorded as "scanned, no text").
    ///
    /// Runs on a detached utility task so many images can be processed
    /// concurrently without blocking the main actor. If the work hangs, it is
    /// abandoned after `timeout` and the caller moves on.
    static func recognizeText(in url: URL) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let gate = ResumeOnce(continuation)
            let work = Task.detached(priority: .utility) {
                gate.resume(await perform(on: url))
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: timeout)
                guard gate.resume(nil) else { return }
                work.cancel()
            }
        }
    }

    /// Resumes a continuation at most once, whichever of work/timeout is first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
        @discardableResult
        func resume(_ value: String?) -> Bool {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            guard let c else { return false }
            c.resume(returning: value)
            return true
        }
    }

    private static func perform(on url: URL) async -> String {
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
