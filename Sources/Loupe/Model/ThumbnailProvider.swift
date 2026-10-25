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

/// Where in a video the thumbnail frame is taken, expressed as a fraction of
/// the clip's duration so it generalizes across clip lengths. Fixing a black
/// `.mp4` thumbnail is often just a matter of moving off the lead-in frame, so
/// this is exposed as a small menu of presets.
///
/// Only the custom decode paths (AVFoundation / FFmpeg) honor this; QuickLook
/// (`.nativeMacOS`) picks its own poster frame and ignores the position.
/// A position is one of two kinds: a *fraction* of the clip's duration (which
/// generalizes across clip lengths) or a fixed number of *seconds* from the
/// start (useful when you know roughly where the interesting frame sits, e.g.
/// after a fixed-length intro). An absolute offset past the end of a short clip
/// is clamped by the decode paths rather than failing.
enum VideoThumbnailPosition: String, CaseIterable, Sendable {
    case start = "Start"
    case tenPercent = "10%"
    case twentyFivePercent = "25%"
    case fiftyPercent = "Middle"
    case seventyFivePercent = "75%"
    case fiveSeconds = "5 seconds"
    case tenSeconds = "10 seconds"
    case thirtySeconds = "30 seconds"

    var displayName: String { rawValue }

    /// How a position is measured.
    enum Measure: Sendable {
        /// A fraction (0…1) of the clip's duration.
        case fraction(Double)
        /// A fixed offset in seconds from the start.
        case seconds(Double)
    }

    var measure: Measure {
        switch self {
        case .start: return .fraction(0)
        case .tenPercent: return .fraction(0.10)
        case .twentyFivePercent: return .fraction(0.25)
        case .fiftyPercent: return .fraction(0.50)
        case .seventyFivePercent: return .fraction(0.75)
        case .fiveSeconds: return .seconds(5)
        case .tenSeconds: return .seconds(10)
        case .thirtySeconds: return .seconds(30)
        }
    }

    /// Resolves this position to a concrete time in seconds given the clip's
    /// `duration` (also in seconds). A fractional position scales with the
    /// duration; an absolute position is clamped so it never lands at or past
    /// the end of a clip shorter than the requested offset — it backs off to
    /// 95% of the duration so there's still a frame to decode. Pass a
    /// non-positive `duration` when the duration is unknown; a fractional
    /// position then resolves to 0 and an absolute one to its raw offset.
    func resolvedSeconds(duration: Double) -> Double {
        switch measure {
        case .fraction(let f):
            guard duration > 0 else { return 0 }
            return duration * f
        case .seconds(let s):
            guard duration > 0 else { return s }
            return min(s, duration * 0.95)
        }
    }

    /// Whether this position is measured from the very start (frame 0), so a
    /// decode path can skip loading the duration entirely.
    var isStart: Bool {
        if case .fraction(0) = measure { return true }
        return false
    }

    /// Whether resolving this position requires knowing the clip's duration.
    /// Absolute-seconds positions don't (except to clamp a short clip), and
    /// `.start` doesn't either.
    var needsDuration: Bool {
        switch measure {
        case .fraction(let f): return f > 0
        case .seconds: return true   // only to clamp; harmless if unavailable
        }
    }

    /// The sensible default: a quarter in, past typical intros/fades.
    static let defaultPosition: VideoThumbnailPosition = .twentyFivePercent
}

/// A `Sendable` wrapper around the thumbnail `NSCache`. `NSCache` is documented
/// as thread-safe for concurrent reads and writes but isn't marked `Sendable`,
/// so this box carries the `@unchecked Sendable` promise in one small, audited
/// place — letting the provider read the cache from a `nonisolated` method (for
/// a synchronous cached-thumbnail lookup) without hopping onto the actor.
private final class ThumbnailCacheBox: @unchecked Sendable {
    let cache = NSCache<NSString, NSImage>()
}

actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    /// The outcome of one generation attempt. Distinguishes a produced image
    /// and a genuine decode failure from a request that was *cancelled* before
    /// it finished (a display change pulled the rug out while it was queued or
    /// decoding).
    ///
    /// The distinction matters because requests dedupe: a `.visible` cell can
    /// `await` an in-flight task that was originally a `.prefetch`, and that
    /// prefetch can be cancelled by `cancelInFlight` when the displayed set
    /// changes. Without this, the still-visible cell would see a bare `nil`,
    /// treat it as a permanent decode failure, and never retry — which stranded
    /// thumbnails in large folders (a cell that happened to share a cancelled
    /// prefetch's task would show the fallback icon forever). `.cancelled` tells
    /// the caller "this didn't fail, it was interrupted — ask again."
    enum GenerationOutcome: Sendable {
        case image(NSImage)
        case failed
        case cancelled

        var image: NSImage? {
            if case .image(let img) = self { return img }
            return nil
        }
    }

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

    /// The thumbnail cache, held in a `Sendable` box so it can be read off the
    /// actor. `NSCache` is internally thread-safe and the reference never
    /// changes; the box just lets a cell read an already-generated thumbnail
    /// synchronously (see `cachedThumbnail`) so a recreated grid cell paints the
    /// cached image on its first frame instead of flashing empty while an async
    /// lookup resolves. Standard actor code still reaches it via `cache`.
    nonisolated private let cacheBox = ThumbnailCacheBox()
    nonisolated private var cache: NSCache<NSString, NSImage> { cacheBox.cache }
    private var inFlight: [URL: Task<GenerationOutcome, Never>] = [:]
    /// The scheduling priority each in-flight URL was last requested at, so a
    /// filter change can cancel only the still-prefetch work (never a cell the
    /// user can see). Updated on create and on promotion; cleared in `finish`.
    private var inFlightPriority: [URL: Priority] = [:]

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
    /// decoding real frames — so only a fraction of the cores run it at once:
    /// enough to keep the decoders busy without a cluster of slow `.mkv` decodes
    /// monopolizing every core while fast image thumbnails wait behind them.
    /// Scales with core count (≈ half the cores) so a many-core machine chews
    /// through a video-heavy folder faster, with a higher ceiling than the old
    /// flat cap of 4 and a floor of 2 for dual-core machines.
    private static let maxConcurrentVideo: Int = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return min(12, max(2, cores / 2))
    }()

    /// Separate, tighter cap on camera-raw image decodes (`.RAF`, `.CR3`, …).
    /// A RAW thumbnail runs ImageIO's full sensor-demosaic pipeline (or the
    /// even heavier Core Image RAW fallback) — far costlier than an ordinary
    /// JPEG/HEIC decode. Letting the generous general gate admit dozens of RAWs
    /// at once thrashed CPU and memory and made the whole grid crawl while a
    /// RAF folder loaded. Bounding them to roughly the core count keeps the
    /// decoders saturated without oversubscription, while ordinary images still
    /// flow through the wide general gate unthrottled. Allowing up to the full
    /// core count (with a higher ceiling than the old 8) lets a RAW folder load
    /// faster on many-core machines while still never oversubscribing.
    private static let maxConcurrentRaw: Int = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return min(16, max(2, cores))
    }()

    /// A much tighter general-gate cap used when the media being thumbnailed
    /// lives on a slow volume — a rotational (spinning) HDD, a removable disk,
    /// or a network mount. The default `maxConcurrent` (16–64) is tuned for a
    /// fast internal SSD where seeks are effectively free; issuing that many
    /// scattered reads to a seek-bound device collapses its throughput, so a
    /// large folder on an external HDD would thrash and stall. A small cap keeps
    /// the disk doing mostly sequential-ish work and lets thumbnails trickle in
    /// steadily instead of freezing. Floored at 2 so there's still a little
    /// overlap to hide per-request latency.
    private static let maxConcurrentSlowVolume = 3

    /// Cached slow/fast classification per volume (keyed by the volume's root
    /// URL), so the costly resource-value probe runs once per disk rather than
    /// once per file. `true` means "slow" (rotational, removable, or network).
    private var slowVolumeCache: [URL: Bool] = [:]

    /// Whether any URL currently admitted or waiting is on a slow volume. The
    /// general gate's effective cap drops to `maxConcurrentSlowVolume` whenever
    /// this is set, so a single external-HDD folder throttles the gate without
    /// penalizing a mixed session's internal-SSD work once the slow work drains.
    private var slowVolumeInUseCount = 0

    /// URLs whose in-flight request counts toward `slowVolumeInUseCount`, so the
    /// increment on request-start is matched by exactly one decrement when the
    /// request ends (in `finish`/`abandon`) regardless of which path it took.
    private var slowVolumeURLs: Set<URL> = []

    /// Records (once) that `url`'s request is slow-volume work, bumping the
    /// shared count. Called when a request is created. Idempotent per URL since
    /// requests dedupe on URL.
    private func noteSlowVolumeStart(_ url: URL) {
        guard isSlowVolume(url) else { return }
        guard slowVolumeURLs.insert(url).inserted else { return }
        slowVolumeInUseCount += 1
    }

    /// Clears `url`'s slow-volume accounting when its request ends. No-op if the
    /// URL wasn't slow-volume work.
    private func noteSlowVolumeEnd(_ url: URL) {
        guard slowVolumeURLs.remove(url) != nil else { return }
        slowVolumeInUseCount -= 1
    }

    /// The general gate's current admission ceiling: the tight slow-volume cap
    /// when slow-volume work is in play, otherwise the generous default.
    private var effectiveMaxConcurrent: Int {
        slowVolumeInUseCount > 0 ? Self.maxConcurrentSlowVolume : Self.maxConcurrent
    }

    /// Classifies the volume `url` lives on as slow (rotational / removable /
    /// network) or fast, caching the result per volume. A failed probe is
    /// treated as fast (the generous default) so an unreadable attribute never
    /// needlessly throttles an internal SSD.
    ///
    /// "Slow" is the union of three signals from the file's volume:
    ///   * not internal (`.volumeIsInternalKey == false`) — covers USB/Thunderbolt
    ///     external disks, the common case here;
    ///   * removable or ejectable — external spinning disks and the like;
    ///   * not local (`.volumeIsLocalKey == false`) — network mounts (SMB/AFP/NFS),
    ///     which are even more latency-bound than a local HDD.
    private func isSlowVolume(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsLocalKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return false
        }
        // Key the cache by the volume root so every file on the same disk shares
        // one probe. Fall back to the file URL if the volume URL is unavailable.
        let volumeKey = values.volume ?? url
        if let cached = slowVolumeCache[volumeKey] {
            return cached
        }

        let notInternal = (values.volumeIsInternal == false)
        let removable = (values.volumeIsRemovable == true) || (values.volumeIsEjectable == true)
        let notLocal = (values.volumeIsLocal == false)
        let slow = notInternal || removable || notLocal

        slowVolumeCache[volumeKey] = slow
        return slow
    }

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

    /// Running count and FIFO backlog for the tight camera-raw decode gate.
    /// Like video, RAW decodes are heavy and a minority of a typical folder, so
    /// a simple first-come queue is enough.
    private var rawRunningCount = 0
    private var rawWaiters: [CheckedContinuation<Void, Never>] = []

    /// Hard cap on a thumbnail's longest edge, in pixels. Grid cells top out at
    /// 320 pt, so on a Retina display the largest cell is 640 physical pixels.
    /// The cap must match that physical size, not the point size — capping at
    /// 320 px decoded a half-resolution thumbnail that AppKit then upscaled 2×
    /// into the cell, which looked soft/blurry (worst on already-small source
    /// images, where there's no spare detail to hide the upscale). Capping at
    /// the largest cell's point size × the maximum backing scale decodes at
    /// true display resolution so thumbnails stay crisp. Memory per thumbnail
    /// rises (a 640²-RGBA image is ~1.6 MB vs ~400 KB at 320²), but the cache is
    /// byte-budgeted and evicts LRU, so it self-limits; smaller cells still cost
    /// proportionally less.
    private static let maxPixelDimension: CGFloat = {
        let maxCellPoints: CGFloat = 320  // BrowserModel.maxThumbnailSize
        let maxScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return (maxCellPoints * maxScale).rounded()
    }()

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
        videoPosition: VideoThumbnailPosition = .defaultPosition,
        priority: Priority = .visible
    ) async -> NSImage? {
        let key = Self.cacheKey(url: url, method: method, videoPosition: videoPosition)
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
        //
        // A request can dedupe onto an in-flight task that then gets cancelled
        // by a display change (most often a `.visible` cell that joined a
        // `.prefetch` already in flight). That comes back `.cancelled`, not a
        // real failure. If THIS request wasn't itself cancelled — i.e. the cell
        // still wants the image — ask again: `taskForThumbnail` starts fresh
        // work since the cancelled task has cleared its in-flight slot. Bounded
        // to a few attempts so a genuinely thrashing set can't spin here; in
        // practice one retry settles it.
        var attempt = 0
        while true {
            let task = taskForThumbnail(
                url: url, pixelSize: pixelSize, method: method,
                videoPosition: videoPosition, priority: priority
            )
            let outcome = await task.value

            if case .cancelled = outcome {
                attempt += 1
                // Stop if this caller was itself cancelled (the cell is gone)
                // or we've retried enough — don't busy-loop on a hot filter.
                if Task.isCancelled || attempt >= Self.maxCancelRetries {
                    return outcome.image
                }
                continue
            }
            return outcome.image
        }
    }

    /// How many times `thumbnail(for:…)` re-requests after a dedup'd task came
    /// back `.cancelled`. A couple of attempts covers the realistic case (a
    /// visible cell that joined a prefetch cancelled by one display change)
    /// without spinning while the user scrubs a filter back and forth.
    private static let maxCancelRetries = 3

    /// Synchronous, non-blocking lookup of an already-generated thumbnail.
    /// Returns the cached image if present, else `nil` — it never generates.
    ///
    /// `nonisolated` so a view can call it during `body` without an `await`:
    /// a grid cell that scrolled off and back is recreated with empty state, so
    /// reading the cache synchronously here lets it paint the thumbnail on its
    /// first frame instead of flashing the fallback icon while an async request
    /// round-trips. The `NSCache` is internally thread-safe, so this is safe to
    /// read off the actor.
    nonisolated func cachedThumbnail(
        for url: URL,
        method: ThumbnailMethod = .hybrid,
        videoPosition: VideoThumbnailPosition = .defaultPosition
    ) -> NSImage? {
        cache.object(forKey: Self.cacheKey(url: url, method: method, videoPosition: videoPosition))
    }

    /// Warms the cache for `url` at low priority without waiting for the result.
    /// Used to prefetch cells just outside the viewport so they're ready by the
    /// time a short scroll brings them in. No-op if already cached or in flight.
    func prefetch(
        _ url: URL,
        size: CGSize,
        scale: CGFloat,
        method: ThumbnailMethod = .hybrid,
        videoPosition: VideoThumbnailPosition = .defaultPosition
    ) {
        let key = Self.cacheKey(url: url, method: method, videoPosition: videoPosition)
        guard cache.object(forKey: key) == nil, inFlight[url] == nil else {
            return
        }
        let pixelSize = Self.clampedPixelSize(pointSize: size, scale: scale)
        _ = taskForThumbnail(
            url: url, pixelSize: pixelSize, method: method,
            videoPosition: videoPosition, priority: .prefetch
        )
    }

    /// Cancels in-flight work for items that are no longer shown, so thumbnail
    /// generation tracks the active folder / filter: when the displayed set
    /// changes (switching the selected folder, a chip filter, search, or a
    /// Library-view switch), work queued or running for now-hidden items
    /// shouldn't keep occupying the scheduler's slots and concurrency gates
    /// ahead of the newly displayed set.
    ///
    /// Cancels work at BOTH priorities for vanished URLs. This matters most on a
    /// folder switch: the previous folder's on-screen cells were requested at
    /// `.visible`, so cancelling only `.prefetch` left those top-priority
    /// decodes running and the new folder's cells queued behind them — exactly
    /// the "doesn't prioritize the active folder" symptom. An item that's no
    /// longer displayed has no visible cell, so its decode — whatever priority
    /// it was requested at — should yield its slot to what's now shown.
    ///
    /// A request already past its slot gate and inside a decoder runs to
    /// completion and caches normally (cooperative cancellation only short-
    /// circuits before a decoder is entered); the win is reclaiming queued slots
    /// and never starting work for vanished items. A still-displayed item is
    /// never cancelled, and any cell still on screen simply re-requests on its
    /// next render.
    ///
    /// `keeping` is the set of URLs still displayed (the new displayed set).
    func cancelInFlight(notIn keeping: Set<URL>) {
        for url in inFlightPriority.keys where !keeping.contains(url) {
            inFlight[url]?.cancel()
        }
    }

    /// Composite cache key so a thumbnail generated under one set of options is
    /// never served when a different set is active — switching the method or
    /// the video position should re-render (that's the whole point). Keyed by
    /// method + video position + URL.
    private static func cacheKey(
        url: URL,
        method: ThumbnailMethod,
        videoPosition: VideoThumbnailPosition
    ) -> NSString {
        "\(method.rawValue)\n\(videoPosition.rawValue)\n\(url.absoluteString)" as NSString
    }

    // MARK: - Gate

    /// Suspends until a generation slot is free, parking the caller in the
    /// priority-ordered `waiters` map keyed by `url`. There is exactly one
    /// `acquireSlot` call per URL (callers are deduped in `taskForThumbnail`),
    /// so each URL owns at most one waiter. A late, higher-priority request for
    /// the same URL doesn't come through here — it goes through `promote`.
    ///
    /// Returns `true` if a generation slot was actually taken (the caller must
    /// `releaseSlot` when it finishes), or `false` if the request was cancelled
    /// before a slot was handed to it (nothing to release — bail instead).
    @discardableResult
    private func acquireSlot(url: URL, priority: Priority) async -> Bool {
        // A request cancelled before it even reaches the gate shouldn't grab a
        // slot via the fast path below; treat it as "no slot taken" so the
        // caller bails cleanly.
        if Task.isCancelled { return false }

        // Take a free slot immediately only when nobody is waiting; otherwise
        // queue so a lower-priority request can't jump an earlier high-priority
        // waiter just because a slot happened to open at that instant. The
        // admission ceiling is `effectiveMaxConcurrent`, which tightens to the
        // slow-volume cap while any slow-disk work is in flight.
        if runningCount < effectiveMaxConcurrent, waiters.isEmpty {
            runningCount += 1
            return true
        }

        // Park until a slot opens. Wrapped in a cancellation handler so a
        // display-change cancel (see `cancelInFlight(notIn:)`) wakes a
        // still-parked waiter instead of leaving it stuck — `Task.cancel()`
        // alone does not resume a continuation. On cancel we resume the waiter
        // and drop it from the queue (without taking a slot); the task body
        // then sees `Task.isCancelled` and bails before decoding.
        var slotTaken = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    // Cancelled before we could park: don't enqueue, don't take
                    // a slot; resume immediately so the task body bails.
                    slotTaken = false
                    continuation.resume()
                    return
                }
                sequence += 1
                waiterOrder[url] = sequence
                waiters[url] = Waiter(priority: priority, resume: continuation)
            }
        } onCancel: {
            Task { await self.resumeCancelledWaiter(url: url) }
        }
        // If we were resumed by the cancel path (not by `releaseSlot` handing
        // us a slot), no slot is held.
        if Task.isCancelled && waiterWasCancelled.remove(url) != nil {
            slotTaken = false
        }
        return slotTaken
    }

    /// URLs whose parked waiter was resumed specifically by cancellation (so
    /// the resumed task knows it did NOT inherit a slot and must not release
    /// one). A set rather than a flag because resume happens on a hop back onto
    /// the actor, decoupled from the awaiting task.
    private var waiterWasCancelled: Set<URL> = []

    /// Resumes and dequeues a parked waiter that was cancelled, so its task can
    /// proceed to its `Task.isCancelled` check and bail. No slot is taken: a
    /// cancelled request never runs a decode. No-op if the waiter already
    /// started (left `waiters`) or was never parked.
    private func resumeCancelledWaiter(url: URL) {
        guard let waiter = waiters.removeValue(forKey: url) else { return }
        waiterOrder[url] = nil
        waiterWasCancelled.insert(url)
        waiter.resume.resume()
    }

    /// Raises the scheduling priority of a URL that's still waiting for a slot.
    /// Called when an in-flight (but not yet started) prefetch becomes visible,
    /// so it's served ahead of other prefetch work without duplicating it.
    private func promote(url: URL, to priority: Priority) {
        // Record the raised priority against the in-flight URL so a later
        // filter-change cancel never drops a prefetch that has since become
        // visible. This runs even once the request has left `waiters` (slot
        // acquired), which is exactly when the waiter lookup below no-ops.
        if let current = inFlightPriority[url], priority > current {
            inFlightPriority[url] = priority
        }
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

    /// Suspends until a camera-raw decode slot is free. Mirrors the video gate:
    /// the caller already holds a general slot while waiting here, which is
    /// fine because `maxConcurrent` is generous and RAW files are a minority of
    /// a typical folder. Bounding RAW concurrency keeps a burst of heavy
    /// demosaic decodes from thrashing the machine.
    private func acquireRawSlot() async {
        if rawRunningCount < Self.maxConcurrentRaw {
            rawRunningCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            rawWaiters.append(continuation)
        }
    }

    /// Frees a camera-raw decode slot and admits the next waiter (FIFO).
    private func releaseRawSlot() {
        if rawWaiters.isEmpty {
            rawRunningCount -= 1
        } else {
            rawWaiters.removeFirst().resume()
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

    /// Converts a requested point size + backing scale into the pixel size to
    /// decode at. The longest edge is always driven to `maxPixelDimension`
    /// (preserving the requested aspect ratio), not merely capped at it.
    ///
    /// Why target the max rather than the exact cell size: the cache is keyed by
    /// method + video position + URL and deliberately NOT by size, so a URL has
    /// one cached bitmap shared across every zoom level. If we decoded at the
    /// current (small) cell size, the first request — often a low-zoom prefetch
    /// — would seed the cache with a small image that a later zoom-in then
    /// upscales into a larger cell, which reads as blurry. Decoding every
    /// thumbnail at the resolution the LARGEST cell needs (320 pt × max backing
    /// scale) keeps the one cached bitmap crisp at all zoom levels. The memory
    /// budget was already sized around `maxPixelDimension`-sized entries, so
    /// this costs nothing the cache wasn't already prepared to hold.
    private static func clampedPixelSize(pointSize: CGSize, scale: CGFloat) -> CGSize {
        let requested = CGSize(
            width: max(1, pointSize.width * scale),
            height: max(1, pointSize.height * scale)
        )
        let longest = max(requested.width, requested.height)
        // Scale the requested box so its longest edge hits maxPixelDimension,
        // whether that means scaling up (small/low-zoom cells) or down (a cell
        // larger than the cap). Aspect ratio is preserved; squares stay square.
        let factor = maxPixelDimension / longest
        return CGSize(
            width: max(1, (requested.width * factor).rounded()),
            height: max(1, (requested.height * factor).rounded())
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
        videoPosition: VideoThumbnailPosition,
        priority: Priority
    ) -> Task<GenerationOutcome, Never> {
        if let existing = inFlight[url] {
            promote(url: url, to: priority)
            return existing
        }

        inFlightPriority[url] = priority
        // Track slow-volume work so the gate throttles while any such request
        // is in play. Done here (new work only, not on the dedup fast path
        // above) so each URL is counted once; `finish`/`abandon` clear it.
        noteSlowVolumeStart(url)

        let kind = MediaKind.classify(url: url)
        let isRaw = kind == .image && MediaKind.isRawImage(url: url)

        let task = Task<GenerationOutcome, Never> { [weak self] in
            // Wait for a generation slot before touching any decoder, so no
            // more than `maxConcurrent` run at once and visible work is admitted
            // ahead of prefetch work. The returned flag says whether a slot was
            // actually taken (vs. the request being cancelled before one was).
            let slotTaken = await self?.acquireSlot(url: url, priority: priority) ?? false

            // A filter change may have cancelled this request while it was
            // parked for a slot (a prefetch for an item that's no longer shown).
            // Bail before touching any decoder so freed capacity goes to the new
            // filtered set's work instead. Use `abandon` (not `finish`) when no
            // slot was held so we never over-release the running count. Report
            // `.cancelled` so a still-visible caller that dedup'd onto this task
            // retries instead of recording a permanent failure.
            if Task.isCancelled {
                await self?.abandon(url: url, hadSlot: slotTaken)
                return .cancelled
            }

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
                await self?.finish(url: url, method: method, videoPosition: videoPosition, image: image)
                return Self.outcome(for: image)
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
                // Camera-raw decodes are heavy (full demosaic / Core Image RAW
                // pipeline), so throttle them through the tight raw gate while
                // ordinary images keep the wide general gate. The caller still
                // holds a general slot while waiting here — fine, since RAWs are
                // a minority and `maxConcurrent` is generous.
                if isRaw { await self?.acquireRawSlot() }
                image = await Self.imageIOThumbnail(
                    for: url,
                    pixelSize: pixelSize,
                    priority: decodePriority
                )
                if isRaw { await self?.releaseRawSlot() }
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
                    position: videoPosition,
                    priority: decodePriority
                )
                await self?.releaseVideoSlot()
            }

            await self?.finish(url: url, method: method, videoPosition: videoPosition, image: image)
            return Self.outcome(for: image)
        }

        inFlight[url] = task
        return task
    }

    /// Maps a finished decode's optional image to a `GenerationOutcome`. A nil
    /// image is reported as `.cancelled` (not `.failed`) when this task was
    /// cancelled, so a still-visible caller retries rather than giving up: a
    /// decode interrupted mid-flight by a display change can return nil even
    /// though the file is perfectly decodable. A nil with no cancellation is a
    /// genuine `.failed` (no decoder could produce a thumbnail — the cell shows
    /// its type icon and does not retry).
    nonisolated private static func outcome(for image: NSImage?) -> GenerationOutcome {
        if let image { return .image(image) }
        return Task.isCancelled ? .cancelled : .failed
    }

    /// Records a finished generation: stores the image under the method-aware
    /// cache key, clears the in-flight entry, and releases the generation slot
    /// so the next waiter can start.
    private func finish(
        url: URL,
        method: ThumbnailMethod,
        videoPosition: VideoThumbnailPosition,
        image: NSImage?
    ) {
        inFlight[url] = nil
        inFlightPriority[url] = nil
        noteSlowVolumeEnd(url)
        if let image {
            cache.setObject(
                image,
                forKey: Self.cacheKey(url: url, method: method, videoPosition: videoPosition),
                cost: Self.byteCost(of: image)
            )
        }
        releaseSlot()
    }

    /// Cleans up a request that bailed on cancellation before any decode ran.
    /// Drops the in-flight bookkeeping and releases a slot ONLY if one was
    /// actually held: a waiter woken by the cancel path never inherited a slot
    /// (see `resumeCancelledWaiter`), so releasing one then would over-count
    /// free slots; whereas a request that took the fast-path slot and was only
    /// cancelled afterward does hold one and must release it.
    private func abandon(url: URL, hadSlot: Bool) {
        inFlight[url] = nil
        inFlightPriority[url] = nil
        noteSlowVolumeEnd(url)
        waiterWasCancelled.remove(url)
        if hadSlot { releaseSlot() }
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
        position: VideoThumbnailPosition,
        priority: TaskPriority
    ) async -> NSImage? {
        if let image = await avFoundationFrame(for: url, pixelSize: pixelSize, position: position) {
            return image
        }

        // No video frame yet. Many files that classify as video actually carry
        // their picture as embedded cover art rather than a video track — an
        // `.m4v`/`.mp4`/`.m4a` audio file with artwork is the common case, and
        // `avFoundationFrame` returns nil for those (it requires a video
        // track). Pull the embedded artwork before falling through to the
        // FFmpeg frame decode, so these files show their cover art instead of a
        // bare film icon.
        if let artwork = await embeddedArtwork(for: url, pixelSize: pixelSize) {
            return artwork
        }

        // AVFoundation couldn't decode this container. Decode a frame with the
        // bundled FFmpeg libraries on a background task so the demux/decode work
        // never touches the cooperative pool's forward-progress guarantees.
        // The detached priority follows the request so a visible video decodes
        // ahead of a prefetched one at the OS scheduler level.
        let maxPixel = Int(max(pixelSize.width, pixelSize.height).rounded())
        return await Task.detached(priority: priority) {
            FFmpegThumbnailer.thumbnail(
                for: url, maxPixelSize: max(1, maxPixel), position: position
            )
        }.value
    }

    /// Extracts embedded cover art from a media file's metadata and scales it
    /// down to a thumbnail. This is how audio-with-artwork files that happen to
    /// use a video container (`.m4v`, `.mp4`, `.m4a`) get a thumbnail: they have
    /// no video track for `avFoundationFrame` to seize a frame from, but they
    /// do carry a picture in their common `artwork` metadata.
    ///
    /// Reads both the asset-level common metadata and each metadata format's
    /// entries (iTunes-style `.m4a`/`.m4v` artwork lives under a format key
    /// rather than the common one in some files), takes the first artwork it
    /// finds, and downscales via ImageIO so a full-resolution cover doesn't
    /// land in the grid at native size. Returns nil when there's no artwork.
    nonisolated private static func embeddedArtwork(
        for url: URL,
        pixelSize: CGSize
    ) async -> NSImage? {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )

        // Collect candidate metadata items: the common set first, then every
        // format-specific set (iTunes, ID3, QuickTime, …). Any of them may hold
        // the artwork depending on how the file was authored.
        var items: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) {
            items.append(contentsOf: common)
        }
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let formatItems = try? await asset.loadMetadata(for: format) {
                    items.append(contentsOf: formatItems)
                }
            }
        }

        // Pull the raw image data from the first artwork item we can read.
        var artworkData: Data?
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) {
                artworkData = data
                break
            }
        }
        guard let data = artworkData else { return nil }

        // Downscale the cover to the thumbnail size via ImageIO rather than
        // loading it at full resolution — album art is often 1000²+ px, which
        // the grid never needs. Falls back to a direct NSImage if the thumbnail
        // decode fails for any reason.
        let maxPixel = Int(max(1, max(pixelSize.width, pixelSize.height).rounded()))
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cgImage, size: .zero)
            }
        }
        return NSImage(data: data)
    }

    /// Pulls a frame via AVFoundation. Returns nil for containers AVFoundation
    /// doesn't support (e.g. Matroska / WebM) so the caller can fall back.
    /// `pixelSize` is already in pixels, so it maps straight to `maximumSize`.
    /// Seeks to `position` as a fraction of the clip's duration; `.start`
    /// resolves to the first frame without needing the duration at all.
    nonisolated private static func avFoundationFrame(
        for url: URL,
        pixelSize: CGSize,
        position: VideoThumbnailPosition
    ) async -> NSImage? {
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

        // Resolve the requested position to a concrete time. `.start` maps to
        // frame 0 and needs no duration (one fewer async round trip). Other
        // positions resolve against the duration: a fractional one scales with
        // it, an absolute-seconds one is clamped so it can't overshoot a short
        // clip. The duration is loaded lazily and only when the position needs
        // it. With infinite tolerance the generator snaps to the nearest
        // keyframe, so a very short clip simply resolves to its first frame.
        let seconds: Double
        if position.isStart {
            seconds = 0
        } else {
            var duration = 0.0
            if position.needsDuration,
               let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0 {
                duration = d.seconds
            }
            seconds = position.resolvedSeconds(duration: duration)
        }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        do {
            let cgImage = try await generator.image(at: time).image
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            return nil
        }
    }
}
