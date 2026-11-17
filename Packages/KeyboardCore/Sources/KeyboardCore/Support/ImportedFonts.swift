import CoreText
import Foundation

/// Stored file names for imported fonts: the original name made safe for a flat directory.
public enum ImportedFontNaming {
    public static let allowedExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]
    private static let maxStemLength = 80

    /// Keeps letters, digits and a few separators; everything else becomes `_`. The extension is
    /// lowercased so the directory listing and the picker agree on it.
    public static func sanitize(_ fileName: String) -> String {
        let name = (fileName as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        var stem = (name as NSString).deletingPathExtension
        stem = String(
            stem.unicodeScalars.map { scalar -> Character in
                let keep =
                    CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == " "
                    || scalar == "."
                return keep ? Character(scalar) : "_"
            })
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if stem.count > maxStemLength { stem = String(stem.prefix(maxStemLength)) }
        if stem.isEmpty { stem = "font" }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// `name.ttf` taken -> `name-2.ttf`, `name-3.ttf`, ...
    public static func unique(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }
}

/// One font file in the library. `family` is nil when the file cannot be read as a font.
public struct ImportedFont: Equatable, Sendable, Identifiable {
    public let storedName: String
    public let family: String?
    public var id: String { storedName }
    public var isReadable: Bool { family != nil }
}

/// Which fonts back a display font, in lookup order.
public enum ImportedFontCascade {
    /// The chosen font first, then every other readable font in import order. Empty when nothing is
    /// chosen or the chosen file is not readable: the system font is used and no font is registered.
    public static func order(chosen: String?, importOrder: [String], readable: Set<String>) -> [String] {
        guard let chosen, !chosen.isEmpty, readable.contains(chosen) else { return [] }
        var seen: Set<String> = [chosen]
        var result = [chosen]
        for name in importOrder where readable.contains(name) && seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }
}

/// Device preferences for imported fonts, in the shared defaults. Absent or empty means the system
/// font, so an install that never imports a font behaves exactly as before.
// UserDefaults is documented thread-safe but not annotated Sendable.
public struct ImportedFontPreferences: @unchecked Sendable {
    public static let orderKey = "fonts.importOrder.v1"
    public static let candidateKey = "fonts.candidate.v1"
    public static let keyLabelKey = "fonts.keyLabel.v1"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var importOrder: [String] {
        get { defaults.stringArray(forKey: Self.orderKey) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Self.orderKey) }
    }

    public var candidateFont: String? {
        get { Self.value(defaults, Self.candidateKey) }
        nonmutating set { Self.store(defaults, Self.candidateKey, newValue) }
    }

    public var keyLabelFont: String? {
        get { Self.value(defaults, Self.keyLabelKey) }
        nonmutating set { Self.store(defaults, Self.keyLabelKey, newValue) }
    }

    private static func value(_ defaults: UserDefaults, _ key: String) -> String? {
        guard let value = defaults.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }

    private static func store(_ defaults: UserDefaults, _ key: String, _ value: String?) {
        if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Reads font files with CoreText without registering them.
public enum ImportedFontReader {
    /// Descriptors of every face in the file; empty when the file is not a font.
    public static func descriptors(at url: URL) -> [CTFontDescriptor] {
        (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
    }

    /// The family name of the file's first face, nil when unreadable.
    public static func familyName(at url: URL) -> String? {
        guard let first = descriptors(at: url).first else { return nil }
        let family = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
        guard let family, !family.isEmpty else { return nil }
        return family
    }

    public static func postScriptName(at url: URL) -> String? {
        guard let first = descriptors(at: url).first else { return nil }
        let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
        guard let name, !name.isEmpty else { return nil }
        return name
    }
}

/// The font files in `<container>/Fonts`. The host app is the only writer; the keyboard reads.
public struct ImportedFontLibrary: Sendable {
    public struct ImportResult: Equatable, Sendable {
        public var imported: [ImportedFont] = []
        /// File names that are not readable fonts.
        public var rejected: [String] = []
    }

    public let directory: URL
    public let preferences: ImportedFontPreferences

    public init(directory: URL, preferences: ImportedFontPreferences) {
        self.directory = directory
        self.preferences = preferences
    }

    public func url(for storedName: String) -> URL {
        directory.appendingPathComponent(storedName, isDirectory: false)
    }

    /// Import order first; files on disk the order does not name follow, sorted by name.
    public func storedNames() -> [String] {
        let onDisk = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter {
                !$0.hasPrefix(".") && ImportedFontNaming.allowedExtensions.contains(($0 as NSString).pathExtension)
            })
        let ordered = preferences.importOrder.filter { onDisk.contains($0) }
        let rest = onDisk.subtracting(ordered).sorted()
        return ordered + rest
    }

    public func list() -> [ImportedFont] {
        storedNames().map { ImportedFont(storedName: $0, family: ImportedFontReader.familyName(at: url(for: $0))) }
    }

    /// Copies readable fonts in; the rest are named in `rejected`. Each file is validated before it is
    /// copied, so a rejected file leaves nothing behind.
    public func importFiles(_ sources: [URL]) -> ImportResult {
        var result = ImportResult()
        guard !sources.isEmpty else { return result }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var taken = Set(storedNames())
        var order = preferences.importOrder.filter { taken.contains($0) }
        for source in sources {
            let original = source.lastPathComponent
            let ext = source.pathExtension.lowercased()
            guard ImportedFontNaming.allowedExtensions.contains(ext),
                let family = ImportedFontReader.familyName(at: source)
            else {
                result.rejected.append(original)
                continue
            }
            let stored = ImportedFontNaming.unique(ImportedFontNaming.sanitize(original), existing: taken)
            let target = url(for: stored)
            let staging = directory.appendingPathComponent(".import-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: source, to: staging)
                try FileManager.default.moveItem(at: staging, to: target)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                result.rejected.append(original)
                continue
            }
            taken.insert(stored)
            order.append(stored)
            result.imported.append(ImportedFont(storedName: stored, family: family))
        }
        preferences.importOrder = order
        return result
    }

    /// Removes the file and its place in the order; a choice that named it goes back to the system font.
    public func delete(_ storedName: String) {
        ImportedFontRuntime.unregister(url(for: storedName))
        try? FileManager.default.removeItem(at: url(for: storedName))
        preferences.importOrder = preferences.importOrder.filter { $0 != storedName }
        if preferences.candidateFont == storedName { preferences.candidateFont = nil }
        if preferences.keyLabelFont == storedName { preferences.keyLabelFont = nil }
    }
}
