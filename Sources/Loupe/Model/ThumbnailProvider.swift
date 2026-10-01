import AppKit
import QuickLookThumbnailing

/// Generates and caches thumbnails for media items using QuickLook.
///
/// The actor only does fast bookkeeping (cache lookup + deduping in-flight
/// requests) and never `await`s the slow QuickLook generation while isolated,
/// so many thumbnails generate concurrently. Awaiting inside the actor would
/// serialize every request behind the previous one — which made the first
/// folder load appear to freeze as hundreds of cells queued up.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 800
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        // Reuse or create the generation task, but DO NOT await it while the
        // actor is isolated — return the task's handle and await it outside, so
        // concurrent requests overlap instead of serializing.
        let task = taskForThumbnail(url: url, size: size, scale: scale)
        return await task.value
    }

    /// Returns an existing in-flight task or starts a new one, recording it so
    /// duplicate requests for the same URL share one generation.
    private func taskForThumbnail(url: URL, size: CGSize, scale: CGFloat) -> Task<NSImage?, Never> {
        if let existing = inFlight[url] {
            return existing
        }

        let task = Task<NSImage?, Never> { [weak self] in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scale,
                representationTypes: .thumbnail
            )
            request.iconMode = true

            let image: NSImage?
            do {
                let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                image = rep.nsImage
            } catch {
                image = nil
            }
            await self?.finish(url: url, image: image)
            return image
        }

        inFlight[url] = task
        return task
    }

    private func finish(url: URL, image: NSImage?) {
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
    }
}
