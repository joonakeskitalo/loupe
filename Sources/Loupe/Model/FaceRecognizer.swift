import Foundation
import CoreImage
import CoreML
import ImageIO
import Vision

/// Which model turns a cropped face into the vector the clusterer compares.
/// Both run fully on-device; they differ in how well distance separates people.
enum FaceRecognitionEngine: String, CaseIterable, Sendable {
    /// Apple's Vision `GenerateImageFeaturePrintRequest`. A general image
    /// descriptor (not face-specific) — always available, decent, but limited.
    case visionFeaturePrint
    /// A dedicated face-identity embedding model (ArcFace/FaceNet-style) loaded
    /// from a bundled or user-provided Core ML file. Far better separation when
    /// a model is present; unavailable until one is installed.
    case coreMLEmbedding

    var displayName: String {
        switch self {
        case .visionFeaturePrint: return "Vision (built-in)"
        case .coreMLEmbedding: return "Face Model (Core ML)"
        }
    }

    /// A reasonable default clustering threshold for the engine's distance
    /// scale, used when no user preference has been set.
    var defaultThreshold: Double {
        switch self {
        case .visionFeaturePrint: return 0.62   // Vision feature-print distance
        case .coreMLEmbedding: return 0.9       // cosine distance on L2-normed embeddings
        }
    }

    /// Sensible slider bounds for the engine's distance scale.
    var thresholdRange: ClosedRange<Double> {
        switch self {
        case .visionFeaturePrint: return 0.3...1.2
        case .coreMLEmbedding: return 0.3...1.4
        }
    }
}

/// An engine-agnostic face descriptor. The clusterer only ever asks for the
/// distance between two of these; the representation (Vision feature print vs.
/// a raw embedding vector) is hidden here so the rest of the system doesn't
/// care which engine produced it. Distances are only meaningful between
/// embeddings from the *same* engine, which the recognizer guarantees by
/// keying its cache on the engine.
enum FaceEmbedding: Sendable {
    case visionPrint(FeaturePrintObservation)
    /// An L2-normalized identity embedding; compared with cosine distance.
    case vector([Float])

    /// Distance to another embedding of the same kind. Returns `nil` for a
    /// mismatched pair (shouldn't happen in practice) so the clusterer skips it.
    func distance(to other: FaceEmbedding) -> Double? {
        switch (self, other) {
        case let (.visionPrint(a), .visionPrint(b)):
            guard let d = try? a.distance(to: b) else { return nil }
            return Double(d)
        case let (.vector(a), .vector(b)):
            return Self.cosineDistance(a, b)
        default:
            return nil
        }
    }

    /// Cosine distance (1 − cosine similarity) between two L2-normalized
    /// vectors. For unit vectors this reduces to a dot product, but we normalize
    /// defensively in case a model doesn't.
    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in 0..<a.count {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return nil }
        let cosine = dot / (na.squareRoot() * nb.squareRoot())
        return 1.0 - cosine
    }
}

/// A single detected face reduced to what the clusterer needs: an
/// engine-agnostic embedding and the detector's confidence.
struct FaceFeaturePrint: Sendable {
    let embedding: FaceEmbedding
    let confidence: Float
}

/// Turns a cropped, upright face image into a `FaceEmbedding`. Implementations
/// are the swappable "engines". `isAvailable` lets the UI disable an engine
/// whose model isn't installed.
protocol FaceEmbedder: Sendable {
    var isAvailable: Bool { get }
    func embed(_ faceImage: CIImage) async -> FaceEmbedding?
}

/// The built-in Vision engine: a `GenerateImageFeaturePrintRequest` over the
/// face crop. Always available.
struct VisionFeaturePrintEmbedder: FaceEmbedder {
    var isAvailable: Bool { true }

    func embed(_ faceImage: CIImage) async -> FaceEmbedding? {
        var request = GenerateImageFeaturePrintRequest()
        request.cropAndScaleAction = .scaleToFill
        guard let print = try? await request.perform(on: faceImage) else { return nil }
        return .visionPrint(print)
    }
}

/// The Core ML engine: runs a dedicated face-embedding model over the face crop
/// via Vision's `CoreMLRequest`, then L2-normalizes the output into a unit
/// vector the clusterer compares with cosine distance.
///
/// ## Installing a model
/// This project does **not** ship a trained model (they're large and carry
/// their own licenses), so this engine is unavailable until you add one.
///
/// Easiest (no build changes): put a compiled `.mlmodelc` (or raw `.mlmodel`)
/// anywhere on disk and set its absolute path in UserDefaults, e.g.
/// `defaults write <app-id> faceEmbeddingModelPath /path/to/FaceEmbedding.mlmodelc`.
/// The loader also compiles a raw `.mlmodel` on the fly.
///
/// Alternatively, bundle it as a resource named `FaceEmbedding.mlmodelc` in the
/// app bundle (requires adding it to the target's resources / `build-app.sh`).
///
/// Any image→vector model works, e.g. an ArcFace/FaceNet export (commonly
/// 112×112 or 160×160 RGB input, 128/512-d output). Vision resizes the *input*
/// for you via `CoreMLRequest.cropAndScaleAction`; we only L2-normalize the
/// *output* embedding and compare with cosine distance. The crop we pass is a
/// padded, upright face.
///
/// When no model is found, `isAvailable` is false and `embed` returns nil, so
/// the UI disables this option and the app stays on the Vision engine.
struct CoreMLFaceEmbedder: FaceEmbedder {
    /// UserDefaults key holding an optional absolute path to a model file.
    static let modelPathDefaultsKey = "faceEmbeddingModelPath"
    /// Bundle resource name looked up when no explicit path is set.
    private static let bundleModelName = "FaceEmbedding"

    /// The loaded Vision model container, resolved once at init. Nil when no
    /// model is installed (the common case until the user adds one).
    /// `CoreMLModelContainer` is Vision's own `@unchecked Sendable` type.
    private let container: CoreMLModelContainer?

    init() {
        self.container = Self.loadModel()
    }

    var isAvailable: Bool { container != nil }

    func embed(_ faceImage: CIImage) async -> FaceEmbedding? {
        guard let container else { return nil }
        var request = CoreMLRequest(model: container)
        // The crop already *is* the face; fill the model's input with it.
        request.cropAndScaleAction = .scaleToFill
        guard let observations = try? await request.perform(on: faceImage) else { return nil }

        guard let vector = Self.firstVector(from: observations) else { return nil }
        return .vector(Self.l2Normalized(vector))
    }

    // MARK: - Loading

    /// Resolves a model from the user-specified path first, then the app
    /// bundle. Returns nil if neither exists or the file won't load.
    private static func loadModel() -> CoreMLModelContainer? {
        let config = MLModelConfiguration()

        // 1. Explicit user path (compiled .mlmodelc or raw .mlmodel).
        if let path = UserDefaults.standard.string(forKey: modelPathDefaultsKey),
           !path.isEmpty {
            if let c = loadModel(at: URL(fileURLWithPath: path), config: config) { return c }
        }

        // 2. Bundled resource (compiled .mlmodelc preferred, else .mlmodel).
        for ext in ["mlmodelc", "mlmodel"] {
            if let url = Bundle.main.url(forResource: bundleModelName, withExtension: ext),
               let c = loadModel(at: url, config: config) {
                return c
            }
        }
        return nil
    }

    /// Loads a model at `url` into a Vision container, compiling a raw
    /// `.mlmodel` on the fly if needed.
    private static func loadModel(at url: URL, config: MLModelConfiguration) -> CoreMLModelContainer? {
        let compiledURL: URL
        if url.pathExtension == "mlmodel" {
            guard let compiled = try? MLModel.compileModel(at: url) else { return nil }
            compiledURL = compiled
        } else {
            compiledURL = url
        }
        guard let mlModel = try? MLModel(contentsOf: compiledURL, configuration: config),
              let container = try? CoreMLModelContainer(model: mlModel) else {
            return nil
        }
        return container
    }

    /// Extracts the embedding vector from the model's output: the first
    /// feature-value observation whose value is a shaped (multi-array) output.
    /// Returns nil if nothing vector-like is found.
    private static func firstVector(from observations: [any VisionObservation]) -> [Float]? {
        for case let obs as CoreMLFeatureValueObservation in observations {
            if let shaped = obs.featureValue.shapedArrayValue(of: Float.self) {
                return shaped.scalars
            }
            if let shaped = obs.featureValue.shapedArrayValue(of: Double.self) {
                return shaped.scalars.map(Float.init)
            }
        }
        return nil
    }

    private static func l2Normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}

/// Extracts face feature prints from images, entirely on-device, so same-person
/// faces can be clustered across a folder without any identity model, cloud
/// service, or names leaving the machine.
///
/// Two Vision passes run per image, both available on macOS 15:
///
///   * `DetectFaceRectanglesRequest` finds each face and its bounding box.
///   * `GenerateImageFeaturePrintRequest`, with its `regionOfInterest` set to a
///     face's box, produces a `FeaturePrintObservation` describing just that
///     face. Distances between these prints (`distance(to:)`) are small for the
///     same person and large for different people — the signal the clusterer in
///     `BrowserModel` thresholds to build "Person N" groups.
///
/// Like `ImageClassifier`/`VideoMetadataProvider`, the actor only does fast
/// bookkeeping (cache lookup + in-flight dedup) and never `await`s the slow
/// Vision work while isolated, so many images process concurrently.
actor FaceRecognizer {
    static let shared = FaceRecognizer()

    /// Per-(URL, engine) face embeddings. Keying on the engine matters because
    /// embeddings from different engines aren't comparable, so switching engines
    /// must recompute rather than reuse. An empty array means "processed, no
    /// face found", so a re-run skips the file instead of re-detecting.
    private struct CacheKey: Hashable { let url: URL; let engine: FaceRecognitionEngine }
    private var cache: [CacheKey: [FaceFeaturePrint]] = [:]
    private var inFlight: [CacheKey: Task<[FaceFeaturePrint], Never>] = [:]

    /// Whether the Core ML engine has a model installed. Cheap to query; the UI
    /// uses it to enable/disable that option.
    func coreMLAvailable() -> Bool { CoreMLFaceEmbedder().isAvailable }

    /// Ignore low-confidence detections — partial/occluded "faces" produce
    /// noisy prints that pollute clusters.
    private static let minFaceConfidence: Float = 0.3

    /// Drop faces the detector rates as poorly captured (very blurry, extreme
    /// angle, tiny). These make unreliable feature prints that split or merge
    /// clusters wrongly. Faces with no quality score are kept.
    private static let minCaptureQuality: Float = 0.2

    /// Fraction of the face box to pad on every side before cropping, so the
    /// feature print sees a bit of hairline/jaw context rather than just the
    /// inner face — which makes same-person matching more stable.
    private static let cropMargin: CGFloat = 0.4

    /// Skip faces whose box is a tiny fraction of the image: they carry too
    /// few pixels to print reliably and are usually background bystanders.
    private static let minFaceAreaFraction: CGFloat = 0.0008

    /// Returns the face embeddings for `url` using `engine`, detecting on first
    /// request and caching per engine (including the empty "no faces" case).
    func faces(for url: URL, engine: FaceRecognitionEngine) async -> [FaceFeaturePrint] {
        let key = CacheKey(url: url, engine: engine)
        if let cached = cache[key] { return cached }
        let task = taskForFaces(key: key)
        return await task.value
    }

    private func taskForFaces(key: CacheKey) -> Task<[FaceFeaturePrint], Never> {
        if let existing = inFlight[key] { return existing }

        let embedder: any FaceEmbedder = key.engine == .coreMLEmbedding
            ? CoreMLFaceEmbedder()
            : VisionFeaturePrintEmbedder()

        let task = Task<[FaceFeaturePrint], Never> {
            await Self.detectFaces(for: key.url, embedder: embedder)
        }
        inFlight[key] = task

        Task { [weak self] in
            let value = await task.value
            await self?.store(value, for: key)
        }
        return task
    }

    private func store(_ value: [FaceFeaturePrint], for key: CacheKey) {
        cache[key] = value
        inFlight[key] = nil
    }

    // MARK: - Vision (on-device, macOS 15+)

    /// Detects faces and generates a feature print for each one.
    ///
    /// Accuracy hinges on three things that the first version got wrong:
    ///
    ///   1. **Orientation.** `CIImage(contentsOf:)` ignores the file's EXIF
    ///      orientation, so a photo shot in portrait decodes sideways and the
    ///      detector — which is orientation-sensitive — misses or mislocates
    ///      faces. We read the orientation tag and bake it into the image up
    ///      front, so everything downstream works in upright display space.
    ///   2. **Real crops, not a region hint.** Rather than printing the whole
    ///      image through a tiny `regionOfInterest` (which yields a weak,
    ///      low-detail descriptor), we crop each face — with margin — into its
    ///      own image and print that at full scale. That gives the feature
    ///      print actual face pixels to describe, which is what makes
    ///      same-person distances meaningful.
    ///   3. **Quality gating.** Blurry, extreme-angle, or tiny faces get a poor
    ///      `captureQuality` score; including them pollutes clusters, so we drop
    ///      them.
    ///
    /// `nonisolated` + detached so the Vision work never serializes behind actor
    /// isolation.
    nonisolated private static func detectFaces(
        for url: URL, embedder: any FaceEmbedder
    ) async -> [FaceFeaturePrint] {
        await Task.detached(priority: .utility) {
            guard let base = CIImage(contentsOf: url) else { return [] }

            // Bake the EXIF orientation into the pixels so the detector and the
            // crops below all operate on an upright image.
            let orientation = Self.orientation(of: url)
            let image = base.oriented(orientation)
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { return [] }

            // 1. Where are the faces? (Image already upright → no orientation
            // arg needed here.)
            let faceRequest = DetectFaceRectanglesRequest()
            let faces: [FaceObservation]
            do {
                faces = try await faceRequest.perform(on: image)
            } catch {
                return []
            }

            // 2. A feature print per usable face, generated from a padded crop
            // of that face in the upright image.
            var prints: [FaceFeaturePrint] = []
            for face in faces {
                guard face.confidence >= minFaceConfidence else { continue }
                if let quality = face.captureQuality?.score, quality < minCaptureQuality {
                    continue
                }

                // Face box → pixel rect in the upright image.
                let faceRect = face.boundingBox.toImageCoordinates(
                    extent.size, origin: .upperLeft
                )
                // Skip specks.
                let areaFraction = (faceRect.width * faceRect.height)
                    / (extent.width * extent.height)
                guard areaFraction >= minFaceAreaFraction else { continue }

                // Pad, clamp to the image, and crop. CIImage uses a lower-left
                // origin, so convert the upper-left rect before cropping.
                let padded = Self.padded(faceRect, by: cropMargin, within: extent.size)
                let cropLowerLeft = CGRect(
                    x: padded.minX,
                    y: extent.height - padded.maxY,
                    width: padded.width,
                    height: padded.height
                )
                let faceImage = image.cropped(to: cropLowerLeft)
                guard !faceImage.extent.isEmpty else { continue }

                // Turn the crop into an embedding via the selected engine.
                if let embedding = await embedder.embed(faceImage) {
                    prints.append(FaceFeaturePrint(embedding: embedding, confidence: face.confidence))
                }
            }
            return prints
        }.value
    }

    /// Reads the EXIF orientation tag from the image file header (cheap — no
    /// pixel decode). Defaults to `.up` when absent.
    nonisolated private static func orientation(of url: URL) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else {
            return .up
        }
        return orientation
    }

    /// Expands `rect` by `fraction` of its size on each side, clamped to an
    /// image of `size`. Used to give the feature print some context around the
    /// detected face box.
    nonisolated private static func padded(
        _ rect: CGRect, by fraction: CGFloat, within size: CGSize
    ) -> CGRect {
        let dx = rect.width * fraction
        let dy = rect.height * fraction
        let expanded = rect.insetBy(dx: -dx, dy: -dy)
        return expanded.intersection(CGRect(origin: .zero, size: size))
    }
}

/// Groups face feature prints into people by distance, with no identities or
/// names — just stable integer person IDs ("Person 1", "Person 2", …).
///
/// Online clustering with a vote (quorum) join rule: each incoming face joins
/// the existing cluster where it's *close to several samples*, not just one —
/// which keeps distinct people from chaining into a single cluster — otherwise
/// it seeds a new cluster. A conservative agglomerative pass afterward stitches
/// a person that still ended up split across clusters. It runs on the main
/// actor as `BrowserModel` feeds it prints in a stable order, so the resulting
/// person IDs are deterministic for a given folder and classification order.
///
/// It's approximate by nature — Vision's generic image feature print isn't a
/// dedicated face-identity embedding — so the threshold trades false merges
/// against false splits. It groups obvious same-person shots well and is enough
/// to browse a folder by who appears in it, but it is not Photos-grade identity
/// recognition.
struct FaceClusterer {
    /// Distance below which two face prints are considered a *close* pair
    /// (Vision's `distance(to:)`). This is the per-pair similarity gate; it is
    /// deliberately NOT used as a single-link join on its own — see `assign`,
    /// which requires several close samples to join, so one coincidentally
    /// close pair can't fuse two people.
    var threshold: Double

    /// How many of a cluster's samples a face must be *close* to before it may
    /// join (a vote/quorum). Single-link (1 close pair) chains unrelated people
    /// together; requiring a few corroborating matches keeps clusters pure.
    /// Clusters smaller than this fall back to requiring that *all* their
    /// samples be close, so a brand-new 1-sample cluster still needs a genuine
    /// match (not a chain).
    private let minVotes = 3

    /// Tighter distance used by the final merge pass. Merging whole clusters is
    /// higher-stakes than adding one face, so it demands closer agreement than
    /// `threshold` — this is the main guard against cascade over-merging.
    private var mergeThreshold: Double { threshold * 0.85 }

    /// Fraction of cross-pairs between two clusters that must be within
    /// `mergeThreshold` before they merge. A single close cross-pair is not
    /// enough (that's what fused distinct people); a solid fraction of the two
    /// clusters' faces must agree.
    private let mergeAgreement = 0.35

    /// Cap on faces kept per cluster for matching. A generous reservoir, keeping
    /// the *best-quality* faces when trimming, so a cluster stays representative
    /// of the person across many photos without unbounded growth.
    private let maxSamples = 24

    private struct Cluster {
        let id: Int
        var samples: [FaceFeaturePrint]
    }

    private var clusters: [Cluster] = []
    private var nextID = 1

    init(threshold: Double = 0.62) {
        self.threshold = threshold
    }

    /// Start numbering new clusters from `id`, so a second pass over newly
    /// added photos doesn't reuse person IDs already shown to the user.
    mutating func seedNextID(_ id: Int) {
        nextID = max(nextID, id)
    }

    /// Number of samples in `cluster` within `threshold` of `face` (its
    /// "votes"), and the single smallest distance (used only as a tiebreak when
    /// several clusters qualify).
    private func support(_ face: FaceFeaturePrint, in cluster: Cluster) -> (votes: Int, nearest: Double) {
        var votes = 0
        var nearest = Double.greatestFiniteMagnitude
        for sample in cluster.samples {
            guard let dd = face.embedding.distance(to: sample.embedding) else { continue }
            if dd <= threshold { votes += 1 }
            if dd < nearest { nearest = dd }
        }
        return (votes, nearest)
    }

    /// Minimum close-sample votes required to join `cluster`: the quorum
    /// `minVotes`, but never more than the cluster currently has (so small
    /// clusters require *all* their samples to be close rather than an
    /// impossible number).
    private func requiredVotes(for cluster: Cluster) -> Int {
        min(minVotes, cluster.samples.count)
    }

    /// Assigns `face` to the best-supported existing cluster that meets the
    /// vote quorum, or creates a new one. "Best" = most votes, ties broken by
    /// nearest sample. Requiring a quorum (not a single close pair) is what
    /// stops distinct people chaining into one cluster.
    mutating func assign(_ face: FaceFeaturePrint) -> Int? {
        var bestIdx: Int?
        var bestVotes = 0
        var bestNearest = Double.greatestFiniteMagnitude

        for (idx, cluster) in clusters.enumerated() {
            let (votes, nearest) = support(face, in: cluster)
            guard votes >= requiredVotes(for: cluster) else { continue }
            if votes > bestVotes || (votes == bestVotes && nearest < bestNearest) {
                bestVotes = votes
                bestNearest = nearest
                bestIdx = idx
            }
        }

        if let bestIdx {
            addSample(face, to: bestIdx)
            return clusters[bestIdx].id
        }

        let id = nextID
        nextID += 1
        clusters.append(Cluster(id: id, samples: [face]))
        return id
    }

    /// Adds `face` to a cluster, keeping at most `maxSamples` of the
    /// highest-confidence faces so the reservoir stays representative.
    private mutating func addSample(_ face: FaceFeaturePrint, to idx: Int) {
        clusters[idx].samples.append(face)
        if clusters[idx].samples.count > maxSamples {
            clusters[idx].samples.sort { $0.confidence > $1.confidence }
            clusters[idx].samples.removeLast(clusters[idx].samples.count - maxSamples)
        }
    }

    /// Second, agglomerative pass: merge two clusters only when a solid
    /// *fraction* of their cross-pairs agree (within the tighter
    /// `mergeThreshold`) — not on a single close pair. The greedy online pass
    /// can still leave one person in two clusters when their faces drifted; this
    /// stitches those back together without the cascade fusion that a
    /// single-pair rule caused. Runs to a fixed point.
    ///
    /// Returns a map from each merged-away cluster ID to the surviving ID it
    /// folded into, so the caller can collapse its per-item person sets.
    mutating func finalizeMerges() -> [Int: Int] {
        var remap: [Int: Int] = [:]

        var mergedSomething = true
        while mergedSomething {
            mergedSomething = false

            outer: for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    if clustersShouldMerge(clusters[i], clusters[j]) {
                        // Fold j into i.
                        let survivor = clusters[i].id
                        let absorbed = clusters[j].id
                        clusters[i].samples.append(contentsOf: clusters[j].samples)
                        if clusters[i].samples.count > maxSamples {
                            clusters[i].samples.sort { $0.confidence > $1.confidence }
                            clusters[i].samples.removeLast(clusters[i].samples.count - maxSamples)
                        }
                        clusters.remove(at: j)

                        // Record the remap, following any chain so a cluster
                        // that already absorbed others still points at the final
                        // survivor.
                        remap[absorbed] = survivor
                        for (k, v) in remap where v == absorbed { remap[k] = survivor }

                        mergedSomething = true
                        break outer
                    }
                }
            }
        }
        return remap
    }

    /// Whether two clusters are the same person: a sufficient *fraction* of all
    /// cross-pairs between them fall within `mergeThreshold`. One close pair is
    /// not enough — that single-link rule is what over-merged distinct people.
    private func clustersShouldMerge(_ a: Cluster, _ b: Cluster) -> Bool {
        var close = 0
        var total = 0
        for fa in a.samples {
            for fb in b.samples {
                guard let d = fa.embedding.distance(to: fb.embedding) else { continue }
                total += 1
                if d <= mergeThreshold { close += 1 }
            }
        }
        guard total > 0 else { return false }
        return Double(close) / Double(total) >= mergeAgreement
    }

}
