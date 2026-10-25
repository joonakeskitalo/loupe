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
        !prepend.isEmpty || !append.isEmpty || numbering || parentFolder || date
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
        var id: URL { source }

        var originalName: String { source.lastPathComponent }
        var newName: String { destination.lastPathComponent }
        /// True when the name actually changes.
        var isChange: Bool { originalName != newName }
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
        // Names already taken in each destination directory, seeded with the
        // files that currently live there minus the ones we're renaming (those
        // are freed up as they move). Guards against two renames colliding and
        // against stomping an unrelated existing file.
        var takenByDirectory: [URL: Set<String>] = [:]
        let renamedSet = Set(urls.map { $0.standardizedFileURL })

        // Seeds the per-directory "taken" set from disk the first time that
        // directory is touched, excluding the files being renamed (their slots
        // are freed as they move). Later lookups read the live cache, which the
        // `reserve` callback keeps growing as names are handed out.
        func seedExistingNames(in directory: URL) {
            guard takenByDirectory[directory] == nil else { return }
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            takenByDirectory[directory] = Set(
                contents
                    .filter { !renamedSet.contains($0.standardizedFileURL) }
                    .map { $0.lastPathComponent.lowercased() }
            )
        }

        var plans: [Plan] = []

        for (index, url) in urls.enumerated() {
            let directory = url.deletingLastPathComponent()
            let ext = url.pathExtension
            let base = url.deletingPathExtension().lastPathComponent

            let newBase = transform(
                baseName: base,
                index: index,
                parentFolderName: directory.lastPathComponent,
                config: config,
                date: date
            )

            // Ensure uniqueness within the destination directory.
            seedExistingNames(in: directory)
            let unique = uniqueBaseName(
                newBase,
                ext: ext,
                existing: takenByDirectory[directory] ?? [],
                reserve: { reserved in
                    takenByDirectory[directory, default: []].insert(reserved.lowercased())
                }
            )

            let fileName = ext.isEmpty ? unique : "\(unique).\(ext)"
            let destination = directory.appendingPathComponent(fileName)
            plans.append(Plan(source: url, destination: destination))
        }

        return plans
    }

    /// Applies the config's components to a single base name. Order is fixed and
    /// deterministic so the result is predictable:
    ///   prefixes:  date, parent folder, number, prepend text
    ///   core:      original base name
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

        // Prepend / append literal text sit closest to the original name.
        var core = base
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
    /// Calls `reserve` with each name it hands out so the next file in the batch
    /// sees it as taken.
    private static func uniqueBaseName(
        _ base: String,
        ext: String,
        existing: Set<String>,
        reserve: (String) -> Void
    ) -> String {
        func fileName(_ b: String) -> String {
            ext.isEmpty ? b : "\(b).\(ext)"
        }

        var candidate = base
        var counter = 2
        while existing.contains(fileName(candidate).lowercased()) {
            candidate = "\(base) (\(counter))"
            counter += 1
        }
        reserve(fileName(candidate))
        return candidate
    }
}
