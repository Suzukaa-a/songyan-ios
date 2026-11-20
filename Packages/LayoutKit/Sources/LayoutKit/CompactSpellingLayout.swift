import Foundation

/// Compact-spelling layouts: physical key structures that need combination disambiguation.
///
/// Eligibility cannot look only at `KeyboardLayoutKind` (`.phone9` / `.merged14`), which describes input
/// method/encoding rather than physical keys: a definition with 26-key `rows` but `input.builtinLayout`
/// mislabeled `merged14` (`LayoutDefinition.validate` checks action validity, not row count vs builtin)
/// would get the disambiguation UI and send real `ambiguitySpellings()` queries to the engine.
///
/// This policy instead proves the shape from the definition's own rows/keys and rejects everything
/// except two provable shapes (fail-closed):
///
///  * standard phone 9-key: delegated to `PhoneKeypadStructure` (rows, digit positions and the `1` slot
///    are provable; calculator-style digit grids and symbol 3x3 are rejected there);
///  * merged letter keys (14-key, 18-key, ...): the keys' codes (`LetterGroupLayout`) split a–z into
///    groups, each key sends a letter of its group, and at least one key covers more than one.
///
/// A 26-key layout never matches: every group has one letter.
public enum CompactSpellingLayout {
    /// Whether the physical definition supports combination disambiguation. A `nil` definition does not (fail-closed).
    public static func matches(_ definition: LayoutDefinition?) -> Bool {
        guard let definition else { return false }
        if PhoneKeypadStructure.matches(definition) { return true }
        return isMergedLetterLayout(definition)
    }

    /// Main rows: drops the definition's own non-encoding control row, if any. Same criterion as
    /// `KeyboardPanelView.definitionMainRows` (`PhoneKeypadRailPolicy`).
    static func mainRows(in definition: LayoutDefinition) -> [LayoutRow] {
        guard PhoneKeypadRailPolicy.controlRowKeys(in: definition) != nil else {
            return definition.rows
        }
        return Array(definition.rows.dropLast())
    }

    /// Merged letter keys: a clean a–z partition by label with fewer keys than letters.
    static func isMergedLetterLayout(_ definition: LayoutDefinition) -> Bool {
        guard let groups = LetterGroupLayout.groups(in: definition) else { return false }
        return groups.count < LetterGroupLayout.alphabet.count
    }
}

public extension CompactSpellingLayout {
    /// Code → the key code it is typed with on a compact layout (QW → q, ABC → 2), read with
    /// `LayoutFold`'s rule; empty for a definition that is not a compact layout or does not fold.
    static func readingKeyMap(for definition: LayoutDefinition?) -> [Character: Character] {
        guard let definition, matches(definition), let kind = LayoutFold.kind(of: definition) else { return [:] }
        return LayoutFold.map(definition, kind: kind) ?? [:]
    }
}
