import Foundation

/// Where an added component lands relative to the original file name: before
/// it (prefix) or after it (suffix). The file extension is always preserved and
/// stays at the very end regardless.
enum RenameAffix: String, CaseIterable, Sendable {
    case prefix
    case suffix

    var displayName: String {
        switch self {
        case .prefix: return "Prefix"
        case .suffix: return "Suffix"
        }
    }
}

/// The date format used when stamping the current date into a name. Kept to a
/// few filesystem-safe presets (no slashes or colons) so the result is always a
/// valid file name.
enum RenameDateFormat: String, CaseIterable, Sendable {
    /// 2026-10-25
    case iso
    /// 20261025
    case compact
    /// 2026-10-25_14-30-05
    case dateTime

    var displayName: String {
        switch self {
        case .iso: return "2026-10-25"
        case .compact: return "20261025"
        case .dateTime: return "2026-10-25_14-30-05"
        }
    }

    var dateFormatPattern: String {
        switch self {
        case .iso: return "yyyy-MM-dd"
        case .compact: return "yyyyMMdd"
        case .dateTime: return "yyyy-MM-dd_HH-mm-ss"
        }
    }

    func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormatPattern
        return formatter.string(from: date)
    }
}

/// A declarative description of a bulk-rename transformation. Every component is
/// optional and they compose: for a given file the new base name is built by
/// starting from the original base name (sans extension) and layering on, in a
/// fixed order, any enabled components. The extension is always re-appended
/// unchanged at the end.
///
/// The transformation is a pure function of the config plus each file's
/// position, so it can drive a live preview in the UI and the actual rename
/// from the same code path.
struct BulkRenameConfig: Sendable, Equatable {
    /// Literal text to place at the front of the base name. Empty = disabled.
    var prepend: String = ""
    /// Literal text to place at the end of the base name. Empty = disabled.
    var append: String = ""

    // MARK: Find & replace

    /// The substring to search for in the original base name. Empty = disabled.
    var findText: String = ""
    /// The text to substitute in place of each `findText` match. May be empty,
    /// which deletes the matched text.
    var replaceText: String = ""
    /// Whether the `findText` match is case-sensitive.
    var replaceCaseSensitive: Bool = false

    // MARK: Number sequence

    /// When true, a running number is inserted into the name.
    var numbering: Bool = false
    /// Where the number goes.
    var numberAffix: RenameAffix = .suffix
    /// The value the sequence starts at (for the first file).
    var numberStart: Int = 1
    /// How many digits to zero-pad the number to (1 = no padding).
    var numberPadding: Int = 2
    /// Step between consecutive numbers.
    var numberStep: Int = 1

    // MARK: Parent folder name

    /// When true, the immediate parent folder's name is added.
    var parentFolder: Bool = false
    var parentFolderAffix: RenameAffix = .prefix

    // MARK: Current date

    /// When true, the current date is added.
    var date: Bool = false
    var dateAffix: RenameAffix = .prefix
    var dateFormat: RenameDateFormat = .iso

    /// The separator placed between the original name and each added component
    /// (and between components on the same side). Defaults to an underscore,
    /// which is safe on every filesystem.
    var separator: String = "_"

    /// Whether this config would change anything at all. Used to disable the
    /// Rename button when nothing is configured.
    var hasAnyComponent: Bool {
        !prepend.isEmpty || !append.isEmpty || !findText.isEmpty
            || numbering || parentFolder || date
    }
}

/// Produces new file names from a `BulkRenameConfig`. Pure and `@Sendable`-safe:
/// given the same inputs it always yields the same outputs, so the sidebar's
/// live preview and `BrowserModel.renameSelection` share one implementation.
enum BulkRenamer {
    /// A single planned rename: the source URL and the destination it should be
    /// moved to. `destination` differs from `source` only in the last path
    /// component.
    struct Plan: Identifiable, Sendable, Equatable {
        var source: URL
        var destination: URL
        /// XMP sidecars that move with a RAW file (`name.xmp` and/or
        /// darktable's `name.RAF.xmp`), keeping Lightroom / Capture One /
        /// Loupe tags attached to the renamed image.
        var sidecars: [Sidecar] = []
        var id: URL { source }

        var originalName: String { source.lastPathComponent }
        var newName: String { destination.lastPathComponent }
        /// True when the name actually changes.
        var isChange: Bool { originalName != newName }
    }

    /// A sidecar file renamed alongside its image.
    struct Sidecar: Sendable, Equatable {
        var source: URL
        var destination: URL
    }

    /// Builds the ordered list of rename plans for `urls` under `config`,
    /// evaluated as of `date` (defaults to now). The `urls` order defines the
    /// numbering sequence — index 0 gets `numberStart`, index 1 gets
    /// `numberStart + numberStep`, and so on.
    ///
    /// Collisions are resolved so no two results in the batch, and no result
    /// against an existing on-disk file outside the batch, clobber each other:
    /// a numeric " (n)" suffix is appended to the base name when needed. This
    /// mirrors how the image/video exporters avoid overwriting.
    static func plans(
        for urls: [URL],
        config: BulkRenameConfig,
        now date: Date = Date()
    ) -> [Plan] {
        // Actual file names in each directory, keyed lowercased (APFS is
        // case-insensitive by default), listed once per directory.
        var listingByDirectory: [URL: [String: String]] = [:]
        func listing(_ directory: URL) -> [String: String] {
            if let cached = listingByDirectory[directory] { return cached }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            var map: [String: String] = [:]
            for url in contents { map[url.lastPathComponent.lowercased()] = url.lastPathComponent }
            listingByDirectory[directory] = map
            return map
        }

        // Pre-pass: find each RAW's existing sidecars. A sidecar is claimed by
        // at most one image (two RAWs with the same base name can't both own
        // `name.xmp`), and the claimed suffix (".xmp", ".RAF.xmp", ".XMP"…) is
        // kept verbatim so only the base name changes.
        var sidecarSuffixes: [URL: [String]] = [:]
        var claimedSidecars: Set<URL> = []
        for url in urls where ImageDecoding.isRAW(url) {
            let directory = url.deletingLastPathComponent()
            let names = listing(directory)
            let base = url.deletingPathExtension().lastPathComponent
            var suffixes: [String] = []
            for candidate in ["\(base).xmp", "\(url.lastPathComponent).xmp"] {
                guard let actual = names[candidate.lowercased()] else { continue }
                let sidecarURL = directory.appendingPathComponent(actual).standardizedFileURL
                guard claimedSidecars.insert(sidecarURL).inserted else { continue }
                suffixes.append(String(actual.dropFirst(base.count)))
            }
            if !suffixes.isEmpty { sidecarSuffixes[url] = suffixes }
        }

        // A selected `.xmp` that belongs to a selected RAW moves with it rather
        // than being renamed (and numbered) on its own, which would detach it.
        let urls = urls.filter { !claimedSidecars.contains($0.standardizedFileURL) }

        // Names already taken in each destination directory, seeded with the
        // files that currently live there minus the ones we're renaming and
        // their sidecars (those slots are freed as they move). Guards against
        // two renames colliding and against stomping an unrelated file.
        var takenByDirectory: [URL: Set<String>] = [:]
        let renamedSet = Set(urls.map { $0.standardizedFileURL }).union(claimedSidecars)

        func seedExistingNames(in directory: URL) {
            guard takenByDirectory[directory] == nil else { return }
            takenByDirectory[directory] = Set(
                listing(directory).compactMap { lower, actual in
                    renamedSet.contains(directory.appendingPathComponent(actual).standardizedFileURL)
                        ? nil : lower
                }
            )
        }

        var plans: [Plan] = []

        for (index, url) in urls.enumerated() {
            let directory = url.deletingLastPathComponent()
            let ext = url.pathExtension
            let base = url.deletingPathExtension().lastPathComponent
            let suffixes = sidecarSuffixes[url] ?? []

            let newBase = transform(
                baseName: base,
                index: index,
                parentFolderName: directory.lastPathComponent,
                config: config,
                date: date
            )

            // Ensure the image name — and every sidecar name it implies — is
            // unique within the destination directory.
            seedExistingNames(in: directory)
            let unique = uniqueBaseName(
                newBase,
                names: { candidate in
                    [ext.isEmpty ? candidate : "\(candidate).\(ext)"] + suffixes.map { candidate + $0 }
                },
                existing: takenByDirectory[directory] ?? [],
                reserve: { reserved in
                    takenByDirectory[directory, default: []].insert(reserved.lowercased())
                }
            )

            let fileName = ext.isEmpty ? unique : "\(unique).\(ext)"
            let destination = directory.appendingPathComponent(fileName)
            let sidecars = suffixes.map { suffix in
                Sidecar(
                    source: directory.appendingPathComponent(base + suffix),
                    destination: directory.appendingPathComponent(unique + suffix)
                )
            }
            plans.append(Plan(source: url, destination: destination, sidecars: sidecars))
        }

        return plans
    }

    /// Applies the config's components to a single base name. Order is fixed and
    /// deterministic so the result is predictable:
    ///   core:      original base name, with find/replace applied first
    ///   prefixes:  date, parent folder, number, prepend text
    ///   suffixes:  append text, number, parent folder, date
    /// (A component only appears on the side its affix selects.)
    static func transform(
        baseName base: String,
        index: Int,
        parentFolderName: String,
        config: BulkRenameConfig,
        date: Date = Date()
    ) -> String {
        let sep = config.separator

        var prefixParts: [String] = []
        var suffixParts: [String] = []

        func place(_ value: String, _ affix: RenameAffix) {
            guard !value.isEmpty else { return }
            switch affix {
            case .prefix: prefixParts.append(value)
            case .suffix: suffixParts.append(value)
            }
        }

        // Date (outermost prefix / innermost-first suffix).
        if config.date {
            place(config.dateFormat.string(from: date), config.dateAffix)
        }
        // Parent folder name.
        if config.parentFolder {
            place(sanitize(parentFolderName), config.parentFolderAffix)
        }
        // Number sequence.
        if config.numbering {
            let value = config.numberStart + index * config.numberStep
            let digits = max(1, config.numberPadding)
            let number = String(format: "%0\(digits)d", value)
            place(number, config.numberAffix)
        }

        // Find & replace operates on the original name first, so prepend /
        // append and the other components wrap the already-substituted text.
        var core = base
        if !config.findText.isEmpty {
            let options: String.CompareOptions = config.replaceCaseSensitive ? [] : [.caseInsensitive]
            core = core.replacingOccurrences(
                of: config.findText,
                with: config.replaceText,
                options: options
            )
        }
        // Prepend / append literal text sit closest to the original name.
        if !config.prepend.isEmpty {
            core = config.prepend + core
        }
        if !config.append.isEmpty {
            core = core + config.append
        }

        var pieces: [String] = []
        pieces.append(contentsOf: prefixParts)
        pieces.append(core)
        pieces.append(contentsOf: suffixParts.reversed())

        // Drop any empty pieces, then join with the separator.
        let joined = pieces.filter { !$0.isEmpty }.joined(separator: sep)
        return joined.isEmpty ? base : joined
    }

    /// Strips path separators and other characters that aren't safe in a file
    /// name, so e.g. a parent-folder component can't inject a "/" and escape
    /// the directory.
    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: illegal).joined(separator: "-")
    }

    /// Returns a base name unique within `directory`, appending " (2)", " (3)",
    /// … only when the first choice is already taken (case-insensitively).
    /// `names` lists every file name a candidate base implies (the image plus
    /// its sidecars); all must be free. Calls `reserve` with each name handed
    /// out so the next file in the batch sees it as taken.
    private static func uniqueBaseName(
        _ base: String,
        names: (String) -> [String],
        existing: Set<String>,
        reserve: (String) -> Void
    ) -> String {
        var candidate = base
        var counter = 2
        while names(candidate).contains(where: { existing.contains($0.lowercased()) }) {
            candidate = "\(base) (\(counter))"
            counter += 1
        }
        names(candidate).forEach(reserve)
        return candidate
    }
}
