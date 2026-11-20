import Foundation

/// The codes each key of a merged layout covers, and the map of what they fold into. One rule for
/// every merged layout, 14, 18 and 9 keys alike, bundled or written by hand: a key covers the codes
/// written on it (`LayoutKey.codes`: letters, strokes, marks) and sends its one-character code. A
/// key's title is only what it shows. A layout that writes no codes keeps the bundled grouping of
/// its kind, read from the bundled layout itself. Turning the map into the engine's fold is the
/// keyboard's step (`CompactFold.of`), which keeps this package free of the engine types.
public enum LayoutFold {
    /// One merged key: the codes it covers, the one it sends first, and what it sends.
    public struct Group: Equatable, Sendable {
        public let codes: [Character]
        public let sends: Character
    }

    /// The merged kinds: the layouts whose keys share codes.
    static let mergedKinds: [LayoutInput.Builtin] = [.merged14, .merged18, .phone9]

    /// The kind of merged layout `definition` is: the layout it is based on, else the bundled merged
    /// layout whose keys send exactly what its keys send (an imported layout that names none); nil
    /// for a layout that is not merged.
    public static func kind(of definition: LayoutDefinition) -> LayoutInput.Builtin? {
        if let declared = definition.input.builtinLayout {
            return mergedKinds.contains(declared) ? declared : nil
        }
        let sent = sentCharacters(definition)
        return mergedKinds.first { Set(bundledMap($0).values) == sent }
    }

    /// Whether `definition` writes its own grouping: some key carries `LayoutKey.codes`.
    public static func writesGroups(_ definition: LayoutDefinition) -> Bool {
        definition.rows.contains { $0.keys.contains { $0.codes != nil } }
    }

    /// The codes written in a key's `LayoutKey.codes`, each once, in order.
    public static func codes(of text: String?) -> [Character] {
        var seen = Set<Character>()
        return (text ?? "").filter { !$0.isWhitespace && seen.insert($0).inserted }.map { $0 }
    }

    /// Each code of the bundled `kind` layout to what its key sends, read from that layout's titles
    /// (`QW` sends q, `ABC` sends 2).
    public static func bundledMap(_ kind: LayoutInput.Builtin) -> [Character: Character] {
        guard mergedKinds.contains(kind) else { return [:] }
        var map: [Character: Character] = [:]
        for key in BuiltinLayouts.preset(for: kind).rows.flatMap(\.keys) {
            guard let sends = sentCode(key) else { continue }
            for letter in key.label.lowercased() where letter.isASCII && letter.isLetter { map[letter] = sends }
        }
        return map
    }

    /// The merged keys of `definition` on a `kind` layout, in row order: each one-character code key
    /// with the codes it covers. Written codes win; without any, each key covers the codes the bundled
    /// grouping sends to its code.
    public static func groups(_ definition: LayoutDefinition, kind: LayoutInput.Builtin) -> [Group] {
        let bundled = writesGroups(definition) ? [:] : bundledMap(kind)
        return definition.rows.flatMap(\.keys).compactMap { key in
            guard let sends = sentCode(key) else { return nil }
            let codes = codesOn(definition, key: key, bundled: bundled)
            return codes.isEmpty ? nil : Group(codes: codes, sends: sends)
        }
    }

    /// The codes `key` covers on `definition`, the one it sends first; empty for a key that covers none.
    public static func codesOn(
        _ definition: LayoutDefinition, kind: LayoutInput.Builtin, key: LayoutKey
    ) -> [Character] {
        codesOn(definition, key: key, bundled: writesGroups(definition) ? [:] : bundledMap(kind))
    }

    private static func codesOn(
        _ definition: LayoutDefinition, key: LayoutKey, bundled: [Character: Character]
    ) -> [Character] {
        guard let sends = sentCode(key) else { return [] }
        let covered: [Character]
        if key.codes != nil {
            covered = codes(of: key.codes)
        } else {
            covered = bundled.filter { $0.value == sends }.keys.sorted()
        }
        return (covered.contains(sends) ? [sends] : []) + covered.filter { $0 != sends }
    }

    /// What `definition` folds into on a `kind` layout, as each code to what its key sends: its
    /// written grouping, or the bundled one when it writes none and its keys send what the bundled
    /// layout's keys send. Nil when a code is on two keys, or a layout without written codes sends
    /// other characters than the bundled one. Whether the map is one the engine can run is
    /// `CompactFold.of`'s question.
    public static func map(_ definition: LayoutDefinition, kind: LayoutInput.Builtin) -> [Character: Character]? {
        let bundled = bundledMap(kind)
        guard !bundled.isEmpty else { return nil }
        if !writesGroups(definition) {
            return sentCharacters(definition) == Set(bundled.values) ? bundled : nil
        }
        var map: [Character: Character] = [:]
        for group in groups(definition, kind: kind) {
            for code in group.codes {
                guard map.updateValue(group.sends, forKey: code) == nil else { return nil }
            }
        }
        return map
    }

    /// `definition` with every key's current codes written on it (`LayoutKey.codes`), so a change to
    /// one key's codes never drops the bundled grouping of the others. A layout that writes codes
    /// already is returned as it is.
    public static func writtenOut(_ definition: LayoutDefinition, kind: LayoutInput.Builtin) -> LayoutDefinition {
        guard !writesGroups(definition) else { return definition }
        var result = definition
        result.rows = definition.rows.map { row in
            LayoutRow(
                keys: row.keys.map { key in
                    let current = codesOn(definition, kind: kind, key: key)
                    return current.isEmpty ? key : key.settingCodes(String(current))
                })
        }
        return result
    }

    /// `key` covering `codes`. A key that sends a code no longer among its own sends the first of
    /// them; a key sending a digit keeps it.
    public static func key(_ key: LayoutKey, covering codes: String) -> LayoutKey {
        let normalized = self.codes(of: codes)
        var result = key.settingCodes(String(normalized))
        if let sends = sentCode(key), !sends.isNumber, !normalized.contains(sends), let first = normalized.first {
            result = result.settingAction(LayoutAction(.code, value: String(first)))
        }
        return result
    }

    /// The codes `definition` writes on two keys of a merged layout; empty for a layout that writes
    /// none or is not merged. Such a layout does not fold until each code is on one key.
    public static func repeated(_ definition: LayoutDefinition) -> [Character] {
        guard let kind = kind(of: definition), writesGroups(definition) else { return [] }
        var counts: [Character: Int] = [:]
        for code in groups(definition, kind: kind).flatMap(\.codes) { counts[code, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.keys.sorted()
    }

    /// Every code `definition`'s keys put into the input method: what each key and each long-press
    /// choice sends, and on a merged layout the codes its keys cover. librime takes one printable
    /// ASCII character per key (`speller.cc`), so a code is one character.
    public static func coverage(_ definition: LayoutDefinition) -> Set<Character> {
        let keys = definition.rows.flatMap(\.keys)
        var result = Set(keys.flatMap(sentCodes))
        result.formUnion(keys.flatMap { codes(of: $0.codes) })
        if let kind = kind(of: definition) { result.formUnion(groups(definition, kind: kind).flatMap(\.codes)) }
        return result
    }

    /// The codes on `definition`'s keys the input method can never take: librime reads a key as one
    /// printable ASCII character other than space (`speller.cc` refuses anything below 0x20 or from
    /// 0x7f), so a stroke drawn as 一 or a full-width mark cannot be a code.
    public static func unusable(_ definition: LayoutDefinition) -> [Character] {
        var seen = Set<Character>()
        return definition.rows.flatMap(\.keys)
            .flatMap { sentCodes($0) + codes(of: $0.codes) }
            .filter { character in
                guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                    (0x21...0x7e).contains(scalar.value)
                else { return seen.insert(character).inserted }
                return false
            }
    }

    /// Everything `key` and its long-press choices send as codes, character by character.
    private static func sentCodes(_ key: LayoutKey) -> [Character] {
        ([key.action] + (key.longPress ?? []).map(\.action))
            .filter { $0.type == .code }
            .flatMap { Array($0.value ?? "") }
    }

    private static func sentCode(_ key: LayoutKey) -> Character? {
        guard key.action.type == .code, let value = key.action.value, value.count == 1 else { return nil }
        return value.first
    }

    /// The letters and digits 2-9 the layout's one-character code keys send.
    private static func sentCharacters(_ definition: LayoutDefinition) -> Set<Character> {
        Set(
            definition.rows.flatMap(\.keys).compactMap { sentCode($0).flatMap { $0.lowercased().first } }
                .filter { ("a"..."z").contains($0) || ("2"..."9").contains($0) })
    }
}
