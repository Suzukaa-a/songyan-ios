import Foundation

/// The letters each letter key of a definition covers, read with `LayoutFold`'s rule: the codes a
/// merged key covers, or the letter a plain key sends. This is the one place that decides whether a
/// definition's letter keys split a–z cleanly, for compact-spelling eligibility and for per-letter
/// hints alike.
public enum LetterGroupLayout {
    /// One group per letter key, in row order, the letter it sends first; nil unless the main rows'
    /// letter keys cover a–z exactly once. A 26-key layout yields 26 single-letter groups.
    public static func groups(in definition: LayoutDefinition?) -> [[Character]]? {
        guard let definition else { return nil }
        let keys = CompactSpellingLayout.mainRows(in: definition).flatMap(\.keys)
        guard !keys.isEmpty else { return nil }
        var seen = Set<Character>()
        var result: [[Character]] = []
        for key in keys {
            guard let group = group(of: key, in: definition), !group.isEmpty,
                group.allSatisfy(alphabet.contains), seen.isDisjoint(with: group)
            else { return nil }
            seen.formUnion(group)
            result.append(group)
        }
        return seen == alphabet ? result : nil
    }

    /// The letters `key` covers on `definition`, the one it sends first; nil for a key that sends no
    /// code. Without a definition the key is read as on a layout that is not merged.
    public static func group(of key: LayoutKey, in definition: LayoutDefinition?) -> [Character]? {
        guard key.action.type == .code, let value = key.action.value, value.count == 1, let sent = value.first
        else { return nil }
        if let definition, let kind = LayoutFold.kind(of: definition) { return LayoutFold.codesOn(definition, kind: kind, key: key) }
        // A layout that is not a merged one: written codes, else the letters its title shows, which
        // must include the one it sends (a 26-key letter; not a radical key, which shows no letter).
        let written = LayoutFold.codes(of: key.codes)
        if !written.isEmpty { return (written.contains(sent) ? [sent] : []) + written.filter { $0 != sent } }
        guard let lowered = value.lowercased().first else { return nil }
        var letters: [Character] = []
        for character in key.label.lowercased() where alphabet.contains(character) {
            if !letters.contains(character) { letters.append(character) }
        }
        return letters.first == lowered ? letters : nil
    }

    static let alphabet = Set("abcdefghijklmnopqrstuvwxyz")
}
