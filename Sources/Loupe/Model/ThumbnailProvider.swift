import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing

/// Generates and caches thumbnails for media items, routing each file to the
/// fastest applicable generator:
///
///   * **Images** go through ImageIO (`CGImageSourceCreateThumbnailAtIndex`),
///     which decodes in-process directly at the target size — it never fully
///     decodes a large photo just to shrink it — and reuses any embedded EXIF
///     thumbnail. This is markedly faster than QuickLook for ordinary photos,
///     which pays an XPC hop to a cross-process agent and general-purpose
///     representation selection. QuickLook remains the fallback if ImageIO
///     can't decode a particular image.
///   * **Video** tries AVFoundation, then the bundled FFmpeg libraries for
///     containers neither QuickLook nor AVFoundation handle (notably .mkv and
///     .webm).
///   * **Everything else** (PDFs, documents, etc.) uses QuickLook, whose
///     generality is exactly what that long tail needs.
///
/// That per-type routing is the default (`ThumbnailMethod.hybrid`). A caller
/// can override it per request: `.nativeMacOS` runs QuickLook for every type
/// (matching Finder, and rendering a video poster frame instead of seeking a
/// keyframe — the way to dodge black `.mp4` thumbnails), while `.custom` uses
/// only the in-process decoders and never QuickLook. The cache is keyed by
/// method, so switching methods re-renders rather than serving a thumbnail
/// built the old way.
///
/// Memory is bounded two ways: each image is capped at `maxPixelDimension` px
/// on its longest edge (so a cell at any zoom level decodes a small image), and
/// the cache evicts least-recently-used entries once the total decoded size
/// exceeds a byte budget scaled to the machine's RAM (`cacheByteLimit`). The
/// number of cached images is not capped — only their summed byte cost is.
///
/// The actor only does fast bookkeeping (cache lookup + deduping in-flight
/// requests) and never `await`s the slow QuickLook generation while isolated,
/// so many thumbnails generate concurrently. Awaiting inside the actor would
/// serialize every request behind the previous one — which made the first
/// folder load appear to freeze as hundreds of cells queued up.
///
/// Generation is **bounded and prioritized**. Rather than firing one unbounded
/// `Task` per cell (which floods QuickLook with hundreds of equal-priority
/// requests and lets off-screen work compete with what the user is looking at),
/// requests pass through a small scheduler:
///
///   * At most `maxConcurrent` generations run at once (≈ the core count), so
///     the decoders stay saturated without thrashing or starving the newly
///     visible cells behind a backlog.
///   * Each request carries a `Priority`. Visible cells ask at `.visible`;
///     the grid warms a window around the viewport at `.prefetch`. The
///     scheduler always starts the highest-priority waiter next, so a fast
///     scroll immediately serves whatever is now on screen instead of draining
///     a queue of scrolled-past cells first.
///   * A waiting request can be *promoted*: if a URL queued at `.prefetch`
///     becomes visible, re-requesting it at `.visible` bumps it to the front
///     without starting duplicate work.
/// How thumbnails are generated. Lets the user trade the default per-type
/// routing against two single-pipeline alternatives when a particular file
/// type thumbnails poorly on one path.
///
/// The motivating case is `.mp4` video: the custom AVFoundation path seeks to a
/// representative keyframe with infinite tolerance, which on some H.264/HEVC
/// `.mp4` files lands on an all-black lead-in frame and produces a black
/// thumbnail. QuickLook (`.nativeMacOS`) renders its own video poster frame and
/// sidesteps that, so a user hitting black `.mp4` thumbnails can switch to it.
enum ThumbnailMethod: String, CaseIterable, Sendable {
    /// Per-type routing (the default): images via ImageIO, video via
    /// AVFoundation→FFmpeg, everything else via QuickLook. Fastest overall.
    case hybrid = "Hybrid"
    /// QuickLook for every file type. Uses the same system-wide thumbnailing
    /// Finder/Quick Look use, so it matches OS behavior and renders video
    /// poster frames rather than seeking a keyframe — the way to dodge black
    /// `.mp4` thumbnails — at the cost of a cross-process hop per thumbnail.
    case nativeMacOS = "Native macOS"
    /// Loupe's own in-process decoders only, never QuickLook: images and any
    /// ImageIO-decodable file via ImageIO, video via AVFoundation→FFmpeg.
    /// Files no in-process decoder handles fall back to a type icon.
    case custom = "Custom"

    var displayName: String { rawValue }

    /// A short explanation shown under each option in the picker.
    var detail: String {
        switch self {
        case .hybrid:
            return "Fastest. ImageIO for images, AVFoundation for video, Quick Look for the rest."
        case .nativeMacOS:
            return "Quick Look for everything. Fixes black .mp4 thumbnails; a bit slower."
        case .custom:
            return "In-app decoders only, no Quick Look. Other file types show a type icon."
        }
    }
}

actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    /// Scheduling priority for a thumbnail request. Higher raw value wins.
    enum Priority: Int, Comparable {
        /// Warming a cell near, but not in, the viewport. Yields to visible work.
        case prefetch = 0
        /// A cell the user can currently see. Served ahead of prefetch work.
        case visible = 1

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    // MARK: - Scheduler

    /// Max thumbnail requests in generation at once. This bounds how many tasks
    /// race (so a 10k-item folder doesn't spawn 10k tasks) and gives the
    /// priority queue something to order, but it's deliberately generous: the
    /// primary path is QuickLook, which is XPC/IO-bound rather than CPU-bound
    /// and runs its own internal parallelism efficiently. A tight core-count
    /// cap here throttled QuickLook below what it handles comfortably and made
    /// the first screenful trickle in instead of landing together, so the limit
    /// scales with cores but stays high.
    private static let maxConcurrent: Int = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return min(64, max(16, cores * 4))
    }()

    /// Separate, much tighter cap on the video-frame fallback
    /// (AVFoundation / FFmpeg). That path is genuinely CPU-heavy — demuxing and
    /// decoding real frames — so a handful running at once saturates the cores
    /// without a single slow `.mkv` holding one of the scarce general slots for
    /// seconds while fast image thumbnails wait behind it.
    private static let maxConcurrentVideo: Int = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return min(4, max(2, cores / 2))
    }()

    /// Number of generations currently running (admitted through the gate).
    private var runningCount = 0

    /// A request parked until a generation slot frees up. Each pending URL has
    /// exactly one entry; `resume` unblocks the single owner that enqueued it.
    private struct Waiter {
        var priority: Priority
        let resume: CheckedContinuation<Void, Never>
    }

    /// URLs waiting for a slot, keyed by URL so a repeat request can promote an
    /// existing waiter instead of adding a duplicate. Insertion order within a
    /// priority is broken by `sequence` so same-priority work stays FIFO.
    private var waiters: [URL: Waiter] = [:]
    /// Monotonic tiebreaker so equal-priority waiters drain in request order.
    private var waiterOrder: [URL: UInt64] = [:]
    private var sequence: UInt64 = 0

    /// Running count and FIFO backlog for the tight video-decode gate. Video
    /// work is CPU-bound and already filtered to the rare container that needs
    /// it, so a simple first-come queue (no priority) is enough here.
    private var videoRunningCount = 0
    private var videoWaiters: [CheckedContinuation<Void, Never>] = []

    /// Hard cap on a thumbnail's longest edge, in pixels. Grid cells top out at
    /// 320 pt, so capping here (rather than honoring the full point-size ×
    /// backing-scale, which would be 640 px on Retina) matches the largest cell
    /// 1:1 while quartering the decoded size versus the old worst case. A
    /// 320²-RGBA image is ~400 KB versus ~1.6 MB at 640². Smaller cells end up
    /// well under the cap and cost proportionally less.
    private static let maxPixelDimension: CGFloat = 320

    /// Byte budget for cached thumbnails: 20% of physical RAM. NSCache evicts
    /// least-recently-used entries once the summed per-image cost exceeds this.
    /// Scaling to RAM lets memory-rich machines keep more thumbnails warm while
    /// staying conservative on smaller ones.
    private static let cacheByteLimit: Int = {
        let fraction = 0.2
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return Int((total * fraction).rounded())
    }()

    init() {
        cache.totalCostLimit = Self.cacheByteLimit
    }

    /// Returns a thumbnail for `url`, generating it if needed. `priority`
    /// controls scheduling when generation is contended: `.visible` work is
    /// served ahead of `.prefetch` work, and re-requesting a queued URL at a
    /// higher priority promotes it. Awaited by the cell that needs the image.
    func thumbnail(
        for url: URL,
        size: CGSize,
        scale: CGFloat,
        method: ThumbnailMethod = .hybrid,
        priority: Priority = .visible
    ) async -> NSImage? {
        let key = Self.cacheKey(url: url, method: method)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Clamp the requested resolution so we never decode/store more pixels
        // than a thumbnail needs. We keep the aspect ratio of the requested
        // size but limit the longest edge to `maxPixelDimension` pixels.
        let pixelSize = Self.clampedPixelSize(pointSize: size, scale: scale)

        // Reuse or create the generation task, but DO NOT await it while the
        // actor is isolated — return the task's handle and await it outside, so
        // concurrent requests overlap instead of serializing.
        let task = taskForThumbnail(url: url, pixelSize: pixelSize, method: method, priority: priority)
        return await task.value
    }

    /// Warms the cache for `url` at low priority without waiting for the result.
    /// Used to prefetch cells just outside the viewport so they're ready by the
    /// time a short scroll brings them in. No-op if already cached or in flight.
    func prefetch(_ url: URL, size: CGSize, scale: CGFloat, method: ThumbnailMethod = .hybrid) {
        let key = Self.cacheKey(url: url, method: method)
        guard cache.object(forKey: key) == nil, inFlight[url] == nil else {
            return
        }
        let pixelSize = Self.clampedPixelSize(pointSize: size, scale: scale)
        _ = taskForThumbnail(url: url, pixelSize: pixelSize, method: method, priority: .prefetch)
    }

    /// Composite cache key so a thumbnail generated under one method is never
    /// served when another method is active — switching methods should re-render
    /// (that's the whole point of switching). Keyed by method + URL.
    private static func cacheKey(url: URL, method: ThumbnailMethod) -> NSString {
        "\(method.rawValue)\n\(url.absoluteString)" as NSString
    }

    // MARK: - Gate

    /// Suspends until a generation slot is free, parking the caller in the
    /// priority-ordered `waiters` map keyed by `url`. There is exactly one
    /// `acquireSlot` call per URL (callers are deduped in `taskForThumbnail`),
    /// so each URL owns at most one waiter. A late, higher-priority request for
    /// the same URL doesn't come through here — it goes through `promote`.
    private func acquireSlot(url: URL, priority: Priority) async {
        // Take a free slot immediately only when nobody is waiting; otherwise
        // queue so a lower-priority request can't jump an earlier high-priority
        // waiter just because a slot happened to open at that instant.
        if runningCount < Self.maxConcurrent, waiters.isEmpty {
            runningCount += 1
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sequence += 1
            waiterOrder[url] = sequence
            waiters[url] = Waiter(priority: priority, resume: continuation)
        }
    }

    /// Raises the scheduling priority of a URL that's still waiting for a slot.
    /// Called when an in-flight (but not yet started) prefetch becomes visible,
    /// so it's served ahead of other prefetch work without duplicating it.
    private func promote(url: URL, to priority: Priority) {
        guard var waiter = waiters[url], priority > waiter.priority else { return }
        waiter.priority = priority
        waiters[url] = waiter
    }

    /// Frees a generation slot and admits the highest-priority waiter next
    /// (ties broken by request order). Called once per generation when it ends.
    private func releaseSlot() {
        guard let nextURL = highestPriorityWaiter() else {
            runningCount -= 1
            return
        }
        let waiter = waiters.removeValue(forKey: nextURL)!
        waiterOrder[nextURL] = nil
        // runningCount stays the same: we hand this slot straight to the waiter.
        waiter.resume.resume()
    }

    /// Suspends until a video-decode slot is free. Separate from the general
    /// gate so a burst of slow video decodes can't starve fast image
    /// thumbnails. The caller already holds a general slot while waiting here;
    /// that's acceptable because `maxConcurrent` is generous and video files are
    /// a small minority of a typical folder.
    private func acquireVideoSlot() async {
        if videoRunningCount < Self.maxConcurrentVideo {
            videoRunningCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            videoWaiters.append(continuation)
        }
    }

    /// Frees a video-decode slot and admits the next waiter (FIFO).
    private func releaseVideoSlot() {
        if videoWaiters.isEmpty {
            videoRunningCount -= 1
        } else {
            // Hand the slot straight to the next waiter; count is unchanged.
            videoWaiters.removeFirst().resume()
        }
    }

    /// Picks the waiting URL to run next: highest `priority`, then earliest
    /// request order within that priority.
    private func highestPriorityWaiter() -> URL? {
        waiters.min { lhs, rhs in
            if lhs.value.priority != rhs.value.priority {
                return lhs.value.priority > rhs.value.priority
            }
            return (waiterOrder[lhs.key] ?? 0) < (waiterOrder[rhs.key] ?? 0)
        }?.key
    }

    /// Converts a requested point size + backing scale into a pixel size whose
    /// longest edge is capped at `maxPixelDimension`.
    private static func clampedPixelSize(pointSize: CGSize, scale: CGFloat) -> CGSize {
        let requested = CGSize(
            width: max(1, pointSize.width * scale),
            height: max(1, pointSize.height * scale)
        )
        let longest = max(requested.width, requested.height)
        guard longest > maxPixelDimension else { return requested }
        let factor = maxPixelDimension / longest
        return CGSize(
            width: (requested.width * factor).rounded(),
            height: (requested.height * factor).rounded()
        )
    }

    /// Returns an existing in-flight task or starts a new one, recording it so
    /// duplicate requests for the same URL share one generation. `pixelSize`
    /// is already in pixels (clamped), so QuickLook runs at scale 1.
    ///
    /// A repeat request for an already-queued URL doesn't start new work; it
    /// just `promote`s the existing waiter if the new priority is higher, which
    /// is how a prefetch becomes visible-priority the moment the cell appears.
    private func taskForThumbnail(
        url: URL,
        pixelSize: CGSize,
        method: ThumbnailMethod,
        priority: Priority
    ) -> Task<NSImage?, Never> {
        if let existing = inFlight[url] {
            promote(url: url, to: priority)
            return existing
        }

        let kind = MediaKind.classify(url: url)

        let task = Task<NSImage?, Never> { [weak self] in
            // Wait for a generation slot before touching any decoder, so no
            // more than `maxConcurrent` run at once and visible work is admitted
            // ahead of prefetch work.
            await self?.acquireSlot(url: url, priority: priority)

            var image: NSImage?
            let decodePriority: TaskPriority = priority == .visible ? .userInitiated : .utility

            // `.nativeMacOS` forces QuickLook for every type — the same
            // thumbnailing Finder/Quick Look use. It renders a video poster
            // frame rather than seeking a keyframe, which is how it dodges the
            // black `.mp4` thumbnails the AVFoundation seek can produce. Video
            // still goes through the tight video gate so a cluster of slow
            // QuickLook video renders can't monopolize the general slots.
            if method == .nativeMacOS {
                if kind == .video { await self?.acquireVideoSlot() }
                image = await Self.quickLookThumbnail(for: url, pixelSize: pixelSize)
                if kind == .video { await self?.releaseVideoSlot() }
                await self?.finish(url: url, method: method, image: image)
                return image
            }

            // Fast path: images decode in-process via ImageIO, straight to the
            // target size. Much cheaper than QuickLook's cross-process agent.
            // Run on a detached task (not the cooperative pool) so the
            // synchronous CG decode runs on a real thread, lets many images
            // decode truly in parallel, and never blocks the async runtime.
            // In `.custom` this also handles any ImageIO-decodable non-video
            // file (there's no QuickLook fallback below), so try it for every
            // non-video type, not just those classified as images.
            if kind == .image || (method == .custom && kind != .video) {
                image = await Self.imageIOThumbnail(
                    for: url,
                    pixelSize: pixelSize,
                    priority: decodePriority
                )
            }

            // General path / image fallback: QuickLook. Covers PDFs, documents,
            // and anything ImageIO couldn't decode. Skipped for video, which has
            // its own decode chain below (QuickLook rarely adds value there and
            // costs an XPC round trip). Skipped entirely under `.custom`, which
            // never touches QuickLook — unhandled types fall back to a type
            // icon in the cell instead.
            if image == nil, kind != .video, method != .custom {
                image = await Self.quickLookThumbnail(for: url, pixelSize: pixelSize)
            }

            // Video: AVFoundation first, then the bundled FFmpeg libraries for
            // containers neither QuickLook nor AVFoundation decode (notably
            // .mkv and .webm). This path is CPU-heavy, so it goes through the
            // tight video gate to keep a cluster of slow decodes from
            // monopolizing the cores.
            if image == nil, kind == .video {
                await self?.acquireVideoSlot()
                image = await Self.videoFrame(
                    for: url,
                    pixelSize: pixelSize,
                    priority: decodePriority
                )
                await self?.releaseVideoSlot()
            }

            await self?.finish(url: url, method: method, image: image)
            return image
        }

        inFlight[url] = task
        return task
    }

    /// Records a finished generation: stores the image under the method-aware
    /// cache key, clears the in-flight entry, and releases the generation slot
    /// so the next waiter can start.
    private func finish(url: URL, method: ThumbnailMethod, image: NSImage?) {
        inFlight[url] = nil
        if let image {
            cache.setObject(
                image,
                forKey: Self.cacheKey(url: url, method: method),
                cost: Self.byteCost(of: image)
            )
        }
        releaseSlot()
    }

    /// QuickLook thumbnail for `url` at `pixelSize` (already in pixels, so
    /// scale 1). The system's general-purpose generator: an XPC hop to the
    /// Quick Look agent that produces the same thumbnail Finder shows. Returns
    /// nil if QuickLook can't represent the file.
    nonisolated private static func quickLookThumbnail(for url: URL, pixelSize: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: pixelSize,
            scale: 1,
            representationTypes: .thumbnail
        )
        request.iconMode = true
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return rep.nsImage
        } catch {
            return nil
        }
    }

    /// Estimated decoded size of an image in bytes (RGBA, 4 bytes per pixel),
    /// used as the NSCache cost so eviction is driven by real memory use.
    private static func byteCost(of image: NSImage) -> Int {
        // Prefer the pixel dimensions of the backing bitmap; fall back to the
        // point size if there's no bitmap representation.
        let pixelWidth: Int
        let pixelHeight: Int
        if let rep = image.representations.first {
            pixelWidth = rep.pixelsWide
            pixelHeight = rep.pixelsHigh
        } else {
            pixelWidth = Int(image.size.width)
            pixelHeight = Int(image.size.height)
        }
        return max(1, pixelWidth * pixelHeight * 4)
    }

    /// Decodes a thumbnail for an image file, in-process and directly at the
    /// requested size. Routes through `ImageDecoding.decodeCGImage`, which runs
    /// ImageIO's fast thumbnail path (capping the longest edge to match our
    /// `maxPixelDimension` clamp, reusing an embedded preview when present) and
    /// transparently falls back to Core Image for files ImageIO decodes to an
    /// all-black frame (notably 10-bit `.HIF`). Returns nil if the file isn't a
    /// decodable image, letting the caller fall back to QuickLook.
    ///
    /// `nonisolated` so it never serializes other thumbnail work behind actor
    /// isolation. The actual decode is synchronous CG work, so it's dispatched
    /// to a `Task.detached` — a real GCD-backed thread rather than one of the
    /// scarce cooperative-pool threads — which lets many images decode in
    /// genuine parallel and keeps a blocking decode from stalling the async
    /// runtime (the same reason the FFmpeg path is detached).
    nonisolated private static func imageIOThumbnail(
        for url: URL,
        pixelSize: CGSize,
        priority: TaskPriority
    ) async -> NSImage? {
        await Task.detached(priority: priority) {
            // `autoreleasepool` drains the large CG temporaries a decode spins
            // up on this worker thread rather than letting them pile up across
            // cells. It matters most for camera-raw files (e.g. Fujifilm
            // `.RAF`): ImageIO's thumbnail decode — and especially the Core
            // Image fallback inside `decodeCGImage` for a RAW that ImageIO
            // can't produce a usable preview for — allocates sensor-sized
            // intermediates, and without an explicit pool a grid full of RAFs
            // held every one of those buffers alive until the enclosing async
            // frame returned, which read as a large, growing memory footprint.
            // This is the same guard the fullscreen preloader already applies.
            autoreleasepool {
                let maxPixel = Int(max(1, max(pixelSize.width, pixelSize.height).rounded()))
                guard let cgImage = ImageDecoding.decodeCGImage(url: url, maxPixelSize: maxPixel) else {
                    return nil
                }
                let size = CGSize(width: cgImage.width, height: cgImage.height)
                return NSImage(cgImage: cgImage, size: size)
            }
        }.value
    }

    /// Extracts a representative frame from a video. Tries AVFoundation first
    /// (hardware-accelerated, cheap for formats it supports) and falls back to
    /// the embedded FFmpeg libraries for containers it can't open — notably
    /// `.mkv` and `.webm`.
    ///
    /// `nonisolated` so it runs off the actor and never serializes other
    /// thumbnail work. Returns nil if no decoder can produce a frame.
    nonisolated private static func videoFrame(
        for url: URL,
        pixelSize: CGSize,
        priority: TaskPriority
    ) async -> NSImage? {
        if let image = await avFoundationFrame(for: url, pixelSize: pixelSize) {
            return image
        }

        // AVFoundation couldn't decode this container. Decode a frame with the
        // bundled FFmpeg libraries on a background task so the demux/decode work
        // never touches the cooperative pool's forward-progress guarantees.
        // The detached priority follows the request so a visible video decodes
        // ahead of a prefetched one at the OS scheduler level.
        let maxPixel = Int(max(pixelSize.width, pixelSize.height).rounded())
        return await Task.detached(priority: priority) {
            FFmpegThumbnailer.thumbnail(for: url, maxPixelSize: max(1, maxPixel))
        }.value
    }

    /// Pulls a frame via AVFoundation. Returns nil for containers AVFoundation
    /// doesn't support (e.g. Matroska / WebM) so the caller can fall back.
    /// `pixelSize` is already in pixels, so it maps straight to `maximumSize`.
    nonisolated private static func avFoundationFrame(for url: URL, pixelSize: CGSize) async -> NSImage? {
        // Skip building a precise duration/timing index: a thumbnail doesn't
        // need frame-accurate seeking, and for some containers that index
        // requires scanning the whole file up front. This alone saves the
        // bulk of the open cost on long videos.
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )

        // If there's no decodable video track, don't bother — let the caller
        // fall back to FFmpeg.
        guard let hasVideo = try? await asset.loadTracks(withMediaType: .video),
              !hasVideo.isEmpty else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Thumbnails don't need the exact requested frame — only something
        // representative. Infinite tolerance lets AVFoundation return the
        // nearest already-decodable keyframe instead of decoding forward from
        // the previous keyframe to hit a precise time, which is the single
        // biggest speedup here (zero tolerance is what makes thumbnailing slow).
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        generator.maximumSize = pixelSize

        // Aim a short way in to skip black lead-in frames. With infinite
        // tolerance this snaps to whatever keyframe is nearest, so there's no
        // need to load the duration first (one fewer async round trip) — very
        // short clips simply resolve to their first keyframe.
        let time = CMTime(seconds: 1, preferredTimescale: 600)

        do {
            let cgImage = try await generator.image(at: time).image
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            return nil
        }
    }
}
