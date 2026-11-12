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
        let pending = Pending()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let gate = ResumeOnce(continuation)
                pending.attach(gate)
                let work = Task.detached(priority: .utility) {
                    if gate.resume(await perform(on: url)) { pending.cancelTasks() }
                }
                let timer = Task.detached(priority: .utility) {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    if gate.resume(nil) { pending.cancelTasks() }
                }
                pending.track([work, timer])
            }
        } onCancel: {
            pending.cancel()
        }
    }

    /// Resumes a continuation at most once, whichever of work/timeout/cancel
    /// is first.
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

    /// Ties one recognition's gate and helper tasks to task cancellation, so
    /// cancelling the OCR pass returns immediately instead of waiting on Vision.
    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: ResumeOnce?
        private var tasks: [Task<Void, Never>] = []
        private var cancelled = false

        func attach(_ gate: ResumeOnce) {
            lock.lock()
            self.gate = gate
            let already = cancelled
            lock.unlock()
            if already { gate.resume(nil) }
        }

        func track(_ new: [Task<Void, Never>]) {
            lock.lock()
            tasks = new
            let already = cancelled
            lock.unlock()
            if already { new.forEach { $0.cancel() } }
        }

        func cancelTasks() {
            lock.lock()
            let current = tasks
            lock.unlock()
            current.forEach { $0.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let gate = self.gate
            let current = tasks
            lock.unlock()
            gate?.resume(nil)
            current.forEach { $0.cancel() }
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
        // Shared decoder: for camera RAW it uses the embedded preview (or
        // CIRAWFilter) instead of ImageIO's full RAW decode, which leaks
        // ~130 MB per file.
        autoreleasepool {
            ImageDecoding.decodeCGImage(url: url, maxPixelSize: maxPixelSize, alwaysDecodeFromFullImage: true)
        }
    }
}
