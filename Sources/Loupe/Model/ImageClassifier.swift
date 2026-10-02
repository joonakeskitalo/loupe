import Foundation
import CoreImage
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Classifies an image entirely on-device and resolves it to a single, short,
/// human-friendly **category** suitable for grouping a folder of photos.
///
/// Two Apple on-device models cooperate here, and both run locally with no
/// network and nothing leaving the machine:
///
///   * **Vision** (`ClassifyImageRequest`) does the actual perception. It
///     returns a ranked list of taxonomy labels for the image ("beach",
///     "golden_retriever", "pizza", …) via the system's built-in CoreML
///     scene/object classifier. This is available on macOS 15, so the feature
///     works on the project's deployment target with no extra setup.
///   * **Foundation Models** (Apple Intelligence's on-device LLM, macOS 26+)
///     optionally *condenses* Vision's raw labels into one clean, title-cased
///     bucket name ("Beach", "Dogs", "Food"), collapsing near-synonyms so a
///     folder doesn't fragment into dozens of hyper-specific labels. It is
///     gated behind `#available`/`canImport`, so on macOS 15 (or when Apple
///     Intelligence is off) we fall back to a tidy-up of Vision's top label.
///
/// The actor only does fast bookkeeping (cache lookup + in-flight dedup) and
/// never `await`s the slow Vision/LLM work while isolated, so many images
/// classify concurrently rather than serializing — the same pattern used by
/// `ThumbnailProvider` and `VideoMetadataProvider`.
actor ImageClassifier {
    static let shared = ImageClassifier()

    /// Resolved category keyed by file URL. An entry is written once a file has
    /// been classified so re-running classification over a folder skips files
    /// that are already done.
    private var cache: [URL: String] = [:]
    private var inFlight: [URL: Task<String?, Never>] = [:]

    /// Minimum Vision confidence for a label to be considered. Vision returns
    /// the full taxonomy regardless of confidence, so without a floor the tail
    /// is dominated by near-zero guesses.
    private static let minConfidence: Float = 0.15

    /// How many of Vision's top labels to keep as the basis for a category.
    /// A handful is enough context for the LLM to pick a bucket, and keeps the
    /// fallback label choice stable.
    private static let topLabelCount = 5

    /// Returns the category for `url`, classifying it on first request and
    /// caching the result. Returns `nil` when the file can't be read as an
    /// image or no label clears the confidence floor.
    func category(for url: URL) async -> String? {
        if let cached = cache[url] { return cached.isEmpty ? nil : cached }

        let task = taskForClassification(url: url)
        return await task.value
    }

    /// Whether `url` already has a cached category (so callers can show a count
    /// of remaining work without triggering classification).
    func isClassified(_ url: URL) -> Bool { cache[url] != nil }

    private func taskForClassification(url: URL) -> Task<String?, Never> {
        if let existing = inFlight[url] { return existing }

        let task = Task<String?, Never> {
            // Perception: Vision's labels, highest-confidence first. Detached so
            // the synchronous-ish CoreML work doesn't sit on the actor.
            let labels = await Self.visionLabels(for: url)
            guard !labels.isEmpty else { return nil }

            // Condensation: an LLM bucket name when Apple Intelligence is
            // available, otherwise a cleaned-up version of the top label.
            let category = await Self.categoryName(from: labels)
            return category
        }
        inFlight[url] = task

        // Record the result (even a nil → "" sentinel) and clear the in-flight
        // entry once it lands, so repeats are served from cache.
        Task { [weak self] in
            let value = await task.value
            await self?.store(value, for: url)
        }
        return task
    }

    private func store(_ value: String?, for url: URL) {
        cache[url] = value ?? ""
        inFlight[url] = nil
    }

    // MARK: - Vision (on-device perception, macOS 15+)

    /// Runs the system image classifier and returns the labels that clear the
    /// confidence floor, highest first. Underscored taxonomy identifiers like
    /// `golden_retriever` are left as-is here; naming is handled downstream.
    ///
    /// `nonisolated` + a detached task so the request never serializes other
    /// classifications behind actor isolation.
    nonisolated private static func visionLabels(for url: URL) async -> [String] {
        await Task.detached(priority: .utility) {
            guard let image = CIImage(contentsOf: url) else { return [] }
            do {
                var request = ClassifyImageRequest()
                request.cropAndScaleAction = .scaleToFit
                let observations = try await request.perform(on: image)
                return observations
                    .filter { $0.confidence >= minConfidence }
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(topLabelCount)
                    .map(\.identifier)
            } catch {
                return []
            }
        }.value
    }

    // MARK: - Category naming

    /// Turns Vision's raw labels into a single display category. Uses the
    /// Foundation Models LLM when it's available (macOS 26 + Apple Intelligence
    /// enabled on this Mac); otherwise falls back to tidying the top label.
    nonisolated private static func categoryName(from labels: [String]) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let llm = await llmCategory(from: labels) {
                return llm
            }
        }
        #endif
        return prettyLabel(labels[0])
    }

    /// Formats a raw Vision identifier as a title-cased phrase, e.g.
    /// `golden_retriever` → "Golden Retriever". Used as the category when the
    /// LLM isn't available.
    private static func prettyLabel(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    #if canImport(FoundationModels)
    /// Asks the on-device LLM to collapse the labels into one short bucket name.
    /// Returns `nil` if the model is unavailable or the response is unusable, so
    /// the caller can fall back to the Vision label.
    @available(macOS 26.0, *)
    nonisolated private static func llmCategory(from labels: [String]) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }

        let instructions = """
        You name photo groups for a photo browser. Given a list of machine \
        vision labels for one image, reply with ONE short, general category \
        name (one to three words, title case) that a person would use to group \
        similar photos. Prefer broad buckets like "Dogs", "Beach", "Food", \
        "Cars", "Documents", "People" over hyper-specific breeds or dishes. \
        Reply with only the category name, nothing else.
        """

        let prompt = "Labels: " + labels.joined(separator: ", ")

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let name = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\".,"))
            guard !name.isEmpty, name.count <= 40 else { return nil }
            return name
        } catch {
            return nil
        }
    }
    #endif
}
