import Foundation
import CoreImage
import ImageIO
import Vision

/// A single detected face in an image, reduced to the data clustering needs:
/// its Vision feature print (a compact perceptual descriptor) and the
/// detector's confidence. The feature print is what lets us tell whether two
/// faces — in different photos — are likely the same person, by measuring the
/// distance between prints.
struct FaceFeaturePrint: Sendable {
    let featurePrint: FeaturePrintObservation
    let confidence: Float
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

    /// Per-URL face prints. An empty array means "processed, no face found", so
    /// a re-run skips the file instead of re-detecting.
    private var cache: [URL: [FaceFeaturePrint]] = [:]
    private var inFlight: [URL: Task<[FaceFeaturePrint], Never>] = [:]

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

    /// Returns the face prints for `url`, detecting on first request and
    /// caching the result (including the empty "no faces" case).
    func faces(for url: URL) async -> [FaceFeaturePrint] {
        if let cached = cache[url] { return cached }
        let task = taskForFaces(url: url)
        return await task.value
    }

    private func taskForFaces(url: URL) -> Task<[FaceFeaturePrint], Never> {
        if let existing = inFlight[url] { return existing }

        let task = Task<[FaceFeaturePrint], Never> {
            await Self.detectFaces(for: url)
        }
        inFlight[url] = task

        Task { [weak self] in
            let value = await task.value
            await self?.store(value, for: url)
        }
        return task
    }

    private func store(_ value: [FaceFeaturePrint], for url: URL) {
        cache[url] = value
        inFlight[url] = nil
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
    nonisolated private static func detectFaces(for url: URL) async -> [FaceFeaturePrint] {
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

                var fpRequest = GenerateImageFeaturePrintRequest()
                // The crop already *is* the face; fill the model's input with it.
                fpRequest.cropAndScaleAction = .scaleToFill
                do {
                    let print = try await fpRequest.perform(on: faceImage)
                    prints.append(FaceFeaturePrint(featurePrint: print, confidence: face.confidence))
                } catch {
                    continue
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
/// This is a deliberately simple online clustering: each incoming face is
/// compared against every existing cluster's representative prints and joins
/// the nearest one whose distance is under `threshold`; otherwise it seeds a
/// new cluster. It runs on the main actor as `BrowserModel` feeds it prints in
/// a stable order, so the resulting person IDs are deterministic for a given
/// folder and classification order.
///
/// It's approximate by nature — Vision's generic image feature print isn't a
/// dedicated face-identity embedding — so the threshold trades false merges
/// against false splits. It groups obvious same-person shots well and is enough
/// to browse a folder by who appears in it, but it is not Photos-grade identity
/// recognition.
struct FaceClusterer {
    /// Max distance for two face prints to be considered the same person.
    /// Vision's prints are compared with `distance(to:)`; this value is tuned
    /// for the face region prints produced above. Lower = stricter (more, purer
    /// clusters); higher = looser (fewer clusters, more risk of merging people).
    var threshold: Double

    /// How many representative prints to keep per cluster. Comparing against a
    /// few samples (rather than one centroid) makes matching robust to pose and
    /// lighting without storing every face.
    private let maxRepresentatives = 4

    private struct Cluster {
        let id: Int
        var representatives: [FeaturePrintObservation]
    }

    private var clusters: [Cluster] = []
    private var nextID = 1

    init(threshold: Double = 0.65) {
        self.threshold = threshold
    }

    /// Start numbering new clusters from `id`, so a second pass over newly
    /// added photos doesn't reuse person IDs already shown to the user.
    mutating func seedNextID(_ id: Int) {
        nextID = max(nextID, id)
    }

    /// Assigns `face` to an existing person cluster or creates a new one, and
    /// returns the person ID it landed in. Returns `nil` only if distance
    /// computation fails for every comparison (treated as unclusterable).
    mutating func assign(_ face: FaceFeaturePrint) -> Int? {
        var bestID: Int?
        var bestDistance = Double.greatestFiniteMagnitude

        for cluster in clusters {
            // Average distance to the cluster's samples, not the single nearest
            // one — one coincidentally close representative shouldn't pull an
            // unrelated face in. Clusters with a close *average* are a stronger
            // same-person signal.
            var sum = 0.0
            var count = 0
            for rep in cluster.representatives {
                guard let d = try? face.featurePrint.distance(to: rep) else { continue }
                sum += Double(d)
                count += 1
            }
            guard count > 0 else { continue }
            let avg = sum / Double(count)
            if avg < bestDistance {
                bestDistance = avg
                bestID = cluster.id
            }
        }

        if let bestID, bestDistance <= threshold {
            // Join the nearest cluster; keep a bounded sample of its faces.
            if let idx = clusters.firstIndex(where: { $0.id == bestID }),
               clusters[idx].representatives.count < maxRepresentatives {
                clusters[idx].representatives.append(face.featurePrint)
            }
            return bestID
        }

        // No cluster close enough: start a new person.
        let id = nextID
        nextID += 1
        clusters.append(Cluster(id: id, representatives: [face.featurePrint]))
        return id
    }
}
