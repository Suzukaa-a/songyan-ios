import CoreText
import Foundation
import os

/// A chosen font plus its fallbacks as PostScript names, carried through the UI as one string in
/// the place a skin's font family goes ("system", "rounded", ...). Names are registered by
/// `ImportedFontRuntime.prepare` before such a string is handed out.
public enum ImportedFontFamily {
    private static let prefix = "imported:"
    private static let separator: Character = "|"

    public static func encode(postScriptNames: [String]) -> String? {
        let names = postScriptNames.filter { !$0.isEmpty && !$0.contains(separator) }
        return names.isEmpty ? nil : prefix + names.joined(separator: String(separator))
    }

    /// The PostScript names, chosen font first; nil for a skin family such as "serif".
    public static func decode(_ family: String) -> [String]? {
        guard family.hasPrefix(prefix) else { return nil }
        let names = family.dropFirst(prefix.count).split(separator: separator).map(String.init)
        return names.isEmpty ? nil : names
    }

    /// The font for `family`, or nil when it is not an imported-font family. The chosen face gets the
    /// others as its cascade list; characters none of them has fall through to the system font.
    public static func ctFont(family: String, size: Double) -> CTFont? {
        let key = "\(family)|\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let names = decode(family) else { return nil }
        let cascade = names.dropFirst().map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0) }
        let attributes: [CFString: Any] = [
            kCTFontNameAttribute: names[0],
            kCTFontCascadeListAttribute: cascade,
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(size), nil)
        cache.setObject(font, forKey: key)
        return font
    }

    // The SwiftUI font path has no cache of its own and asks per body evaluation. NSCache is internally synchronized.
    nonisolated(unsafe) private static let cache = NSCache<NSString, CTFont>()
}

/// Registers imported fonts for the current process. A keyboard extension registers only when a font
/// is chosen, and only that font and its fallbacks.
public enum ImportedFontRuntime {
    private static let registered = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Registers the chosen font and its fallbacks, then returns the family string to draw with; nil
    /// (system font) when nothing is chosen or the chosen file is missing or not a font. Does file
    /// I/O: call it off the main thread.
    public static func prepare(chosen: String?, library: ImportedFontLibrary) -> String? {
        guard let chosen, !chosen.isEmpty else { return nil }
        let order = library.storedNames()
        var faces: [String: String] = [:]
        for name in order {
            if let ps = ImportedFontReader.postScriptName(at: library.url(for: name)) { faces[name] = ps }
        }
        let names = ImportedFontCascade.order(chosen: chosen, importOrder: order, readable: Set(faces.keys))
        guard !names.isEmpty else { return nil }
        register(names.map { library.url(for: $0) })
        return ImportedFontFamily.encode(postScriptNames: names.compactMap { faces[$0] })
    }

    private static func register(_ urls: [URL]) {
        let fresh = registered.withLock { set in urls.filter { set.insert($0.path).inserted } }
        guard !fresh.isEmpty else { return }
        // An already-registered font reports an error that is not a failure here.
        CTFontManagerRegisterFontURLs(fresh as CFArray, .process, true, nil)
    }

    /// Lets go of a registration before its file is deleted, so a later import under the same name
    /// registers the new file.
    public static func unregister(_ url: URL) {
        let known = registered.withLock { $0.remove(url.path) != nil }
        if known { CTFontManagerUnregisterFontURLs([url] as CFArray, .process, nil) }
    }
}
