import Foundation
import Yams

/// The install-time Rime patch for the frozen kagiroi package.
///
/// The scheme binds minus/equal to paging while a menu is open, which takes the
/// romaji long-vowel key away from the speller, and its half-width comma and period
/// are candidate lists instead of direct commits. Both are frontend concerns, so the
/// install writes a *.custom.yaml beside the package bytes; the package source is
/// never edited, and a source that does not install kagiroi is left alone.
enum JapaneseSchemePresets {
    static let schemaID = "kagiroi"
    static let patchPath = "kagiroi.custom.yaml"

    /// The preset file the source schema patches for its paging bindings.
    private static let pagingPreset = "key_bindings/paging_with_minus_equal"
    private static let halfShapeComma = "punctuator/half_shape/,"
    private static let halfShapePeriod = "punctuator/half_shape/."

    /// Adds or extends the scheme's patch file. The package's own files stay byte for
    /// byte, and an existing custom file keeps the entries it already has.
    static func supplement(_ files: inout [String: Data]) {
        guard
            let schemaData = files[schemaID + ".schema.yaml"],
            let document = try? BoundedYAML.load(yaml: String(decoding: schemaData, as: UTF8.self)),
            let schema = normalized(document) as? [String: Any],
            let keyBinderValue = schema["key_binder"],
            let keyBinder = normalized(keyBinderValue) as? [String: Any]
        else { return }

        var patch: [String: Any] = [
            halfShapeComma: ["commit": "、"],
            halfShapePeriod: ["commit": "。"],
        ]
        if let paging = pagingPatch(keyBinder: keyBinder) {
            patch.merge(paging) { _, written in written }
        }
        guard let merged = mergedPatch(existing: files[patchPath], adding: patch) else { return }
        files[patchPath] = merged
    }

    /// The paging half of the patch, which depends on the shape of the package.
    ///
    /// The source package keeps key_binder/bindings as an in-place __patch of preset
    /// files whose content the frontend cannot flatten, so emptying that preset's
    /// __append is the only declarative removal. A prebuilt package already carries
    /// one flat list, and its import_preset has to go with it: librime's legacy
    /// preset link appends the frontend prelude's default.yaml (which links the
    /// paging preset again) after custom patches, and a null patch entry is dropped
    /// before it applies, so the section is replaced as a whole.
    private static func pagingPatch(keyBinder: [String: Any]) -> [String: Any]? {
        guard let bindings = keyBinder["bindings"] else { return nil }
        if let flat = normalized(bindings) as? [Any], !flat.isEmpty {
            let list = flat.compactMap { $0 as? [String: Any] }
            guard list.count == flat.count else { return nil }
            let kept = list.filter { !isPagingBinding($0) }
            guard kept.count < list.count else { return nil }
            return ["key_binder": ["bindings": kept]]
        }
        guard let inPlace = normalized(bindings) as? [String: Any],
            let directive = inPlace["__patch"],
            let path = pagingPresetPath(in: directive)
        else { return nil }
        return [path + "/__append": [Any]()]
    }

    private static func pagingPresetPath(in directive: Any?) -> String? {
        if let list = directive as? [Any] {
            return list.compactMap { pagingPresetPath(in: $0) }.first
        }
        guard let reference = directive as? String, reference.contains(pagingPreset),
            let separator = reference.range(of: ":/")
        else { return nil }
        return String(reference[separator.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isPagingBinding(_ binding: [String: Any]) -> Bool {
        guard let accept = binding["accept"] as? String, accept == "minus" || accept == "equal",
            let send = binding["send"] as? String
        else { return false }
        return send == "Page_Up" || send == "Page_Down"
    }

    /// The installed custom file with the patch entries added. A file that does not
    /// load as a mapping is left as it is: an unreadable author patch is not worth
    /// overwriting.
    private static func mergedPatch(existing: Data?, adding patch: [String: Any]) -> Data? {
        var root: [String: Any] = [:]
        if let existing {
            guard
                let document = try? BoundedYAML.load(yaml: String(decoding: existing, as: UTF8.self)),
                let normalizedRoot = normalized(document) as? [String: Any]
            else { return nil }
            root = normalizedRoot
        }
        var entries = root["patch"] as? [String: Any] ?? [:]
        entries.merge(patch) { _, written in written }
        root["patch"] = entries
        guard let text = try? Yams.dump(object: root, allowUnicode: true, sortKeys: true) else {
            return nil
        }
        return Data(text.utf8)
    }

    /// A loaded document as plain Swift containers with String keys, so it can be
    /// merged and dumped again whatever the parser produced for it.
    private static func normalized(_ value: Any) -> Any {
        if let mapping = value as? [String: Any] {
            return mapping.mapValues { normalized($0) }
        }
        if let mapping = value as? [AnyHashable: Any] {
            var result: [String: Any] = [:]
            for (key, item) in mapping {
                guard let name = key as? String else { continue }
                result[name] = normalized(item)
            }
            return result
        }
        if let list = value as? [Any] {
            return list.map { normalized($0) }
        }
        return value
    }
}
