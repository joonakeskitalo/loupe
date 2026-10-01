import AppKit
import QuickLookThumbnailing

/// Generates and caches thumbnails for media items using QuickLook.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 500
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scale,
                representationTypes: .thumbnail
            )
            do {
                let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                return rep.nsImage
            } catch {
                return nil
            }
        }

        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }
}
