import CryptoKit
import Foundation
import KeyboardCore
import Yams

// MARK: - Table-source (shape-code) compact companions — DIRECT-CODE rewrite (v3)
//
// Wubi/Cangjie-style sources are `table_translator` schemes: their primary
// dictionary carries shape CODES (a-z) as the token inventory. The compact
// layouts fold those codes onto their sent letters / 9 digits. A destructive fold would
// drop the original code and make a chosen code impossible to lock, so instead
// this file builds a companion that KEEPS every source code as its own spelling
// and ADDS the folded compact key with one `derive/<letter>/<fold>/` rule per
// source-alphabet letter. The result is bounded (<= the alphabet size, NOT the
// code count): the prism then contains both the compact keys (which enumerate the
// fold class) and the source codes (each a unique key), so a chosen code can be
// rewritten DIRECTLY with no per-code alias.
//
// Soundness: every compact key is a fold FIXPOINT (each letter-group key sends
// its group's first letter, and the 2-9 digits are unchanged by the fold rules). A partial fold is therefore
// compact-typeable only when its unfolded remainder is already compact, i.e. only
// when it already equals the full fold. Any partial/garbage spelling is
// non-typeable from the compact layout and can never add a wrong interpretation.
// An exact pick of a key's own letter sends the fold's exact token, derived from
// that letter alone before any fold rule runs.
//
// Authorization is the same source/producer check as the alias
// mode, but the wire capability is `direct_token_rewrite_v3` with NO lock_map and
// a bounded `direct_tokens` deploy-check sample. The runtime re-proves each
// reported option against the live prism; the token domain is never enumerated.

public extension CompactSchemaAdapter {

    static let foldableLetters = "abcdefghijklmnopqrstuvwxyz"
    /// Pass-through punctuation the compact layouts use; never folded.
    static let foldablePunctuation = ";'/`"

    /// Removes, ahead of a 9-key fold, every spelling that carries a source digit. On
    /// the 9-key layout the digits are the letter keys, so a digit the source spells
    /// with (a tone mark, for example) would read as a key press once the letters fold:
    /// third-tone `hao9` would become `4269`, the code of `hao` followed by w/x/y/z.
    /// Alias spellings (`90…`, prepended by the alias layer) are kept for the rewrite;
    /// each contains `0`, which no compact key sends, so typing never reaches them.
    static let sourceDigitSpellingErase = "erase/^(?!\(tokenAliasSentinel)[0-9]*$).*[0-9].*$/"

    /// Whether the 9-key companion of this source must apply `sourceDigitSpellingErase`:
    /// the source spells with digits but is not itself a telephone-digit code space,
    /// whose digits already mean what the keys mean.
    static func erasesSourceDigitSpellings(_ projection: SourceProjection) -> Bool {
        guard !isNumericCodeSource(projection) else { return false }
        return projection.syllables.contains { syllable in
            syllable.spellings.contains { spelling in
                spelling.text.contains { $0.isASCII && $0.isNumber }
            }
        }
    }

    /// A validated physical fold for one source alphabet.
    struct PhysicalFold: Equatable, Sendable {
        /// `exactTokenRules`, then `derive/<source letter>/<compact key>/`, one per
        /// present source letter.
        public let rules: [String]
        /// `derive/<letter>/<exact token>/` for each key letter that another present
        /// letter folds onto; they run before the fold so they see that letter only.
        public let exactTokenRules: [String]
        /// The exact tokens in use, in rule order.
        public let exactTokens: String
        /// `xlit/<tokens>/<letters>/`, so an exact pick shows its letter in the preedit;
        /// nil when no exact token is in use.
        public let exactTokenPreedit: String?
        /// The source's own physical input alphabet.
        public let sourceAlphabet: String
        /// The alphabet the companion must accept so both the compact keys and the
        /// direct source codes can re-syllabify.
        public let typeableAlphabet: String
        /// Declared source characters the compact layout never sends, sorted. They are
        /// neither folded nor accepted by the companion.
        public let ignoredCharacters: String
    }

    /// The SINGLE physical-alphabet contract consumed by BOTH `adaptability` and
    /// `generate`, so a source can never pass one and fail the other.
    ///
    /// Returns nil only when the source declares no lowercase Latin letter at all:
    /// there is then nothing a compact layout can fold. Every other declared
    /// character is either typeable on the compact layout or ignored:
    ///   * typeable: the lowercase letters (folded), the pass-through punctuation,
    ///     uppercase letters whose lowercase key is also declared (Rime's common
    ///     `zyx...aZYX...A` case alias), and the 2–9 digits on a 9-key fold (whether
    ///     a source digit means the same as the telephone key is decided by the
    ///     generator, see `sourceDigitSpellingErase`);
    ///   * ignored: anything else, such as tone digits, `\`, an uppercase-only key or
    ///     a non-Latin character. Compact layouts commit digits and symbols directly
    ///     and never send these characters into the composition, so the companion
    ///     neither folds them nor accepts them. Spellings that need them stay
    ///     unreachable on the compact layout, exactly as if the key did not exist.
    /// Fold rules are generated only for physical keys actually present. Paired
    /// uppercase keys get their own derive to the same compact key: table dictionaries
    /// may use case-significant codes, so accepting an uppercase declaration must not
    /// make those tokens unreachable. A key the source does not have is never invented
    /// (a lowercase present-letter fold is a no-op when it maps to itself).
    static func physicalFold(sourceAlphabet: String, fold compactFold: CompactFold) -> PhysicalFold? {
        let nineKey = compactFold.isPhoneDigits
        let source = Set(sourceAlphabet)
        let uppercaseLetters = Set(foldableLetters.uppercased())
        // Deterministic order over the canonical letter order, restricted to the
        // letters this source actually declares.
        let present = foldableLetters.filter { sourceAlphabet.contains($0) }
        guard !present.isEmpty else { return nil }
        var passThrough = Set(foldablePunctuation)
        if nineKey { passThrough.formUnion("23456789") }
        let ignored = sourceAlphabet.filter { character in
            if character.isLowercase, present.contains(character) { return false }
            if passThrough.contains(character) { return false }
            guard uppercaseLetters.contains(character), let lowercase = character.lowercased().first else { return true }
            return !source.contains(lowercase)
        }

        let foldMap = compactFold.map
        // A key letter needs an exact token only when another present letter shares its key.
        let sharedKeys = Set(present.compactMap { letter in foldMap[letter].flatMap { $0 == letter ? nil : $0 } })
        let exactTokens = present.filter(sharedKeys.contains).compactMap { letter in
            compactFold.exactTokens[letter].map { (letter, $0) }
        }
        let exactTokenRules = exactTokens.map { "derive/\($0.0)/\($0.1)/" }
        var rules = exactTokenRules
        for letter in present {
            guard let folded = foldMap[letter] else { continue }
            if folded != letter { rules.append("derive/\(letter)/\(folded)/") }
            let uppercase = Character(String(letter).uppercased())
            if source.contains(uppercase) {
                rules.append("derive/\(uppercase)/\(folded)/")
            }
        }
        // The compact keys must exist for the layout to be reachable, and the
        // source letters must remain typeable so a direct code can re-syllabify.
        let compactKeys = compactFold.keysSent
        // Lowercase compact keys are what the physical layout emits. Paired uppercase
        // source keys must nevertheless stay in the companion alphabet because the
        // direct-rewrite transaction sets the chosen exact source token before asking
        // librime to re-syllabify it.
        let declaredUppercase = source.filter {
            uppercaseLetters.contains($0) && !ignored.contains($0)
        }
        let typeable = String(
            Set(compactKeys).union(Set(present))
                .union(exactTokens.map(\.1))
                .union(declaredUppercase)
                .union(sourceAlphabet.filter { foldablePunctuation.contains($0) }).sorted())
        return PhysicalFold(
            rules: rules,
            exactTokenRules: exactTokenRules,
            exactTokens: String(exactTokens.map(\.1)),
            exactTokenPreedit: exactTokens.isEmpty
                ? nil
                : "xlit/\(String(exactTokens.map(\.1)))/\(String(exactTokens.map(\.0)))/",
            sourceAlphabet: sourceAlphabet,
            typeableAlphabet: typeable,
            ignoredCharacters: String(Set(ignored).sorted()))
    }

    /// Whether typing on the compact layout can reach at least one of the source's
    /// spellings: one made only of keys the layout sends (and, when the 9-key companion
    /// erases digit spellings, free of digits). A source that spells only with ignored
    /// keys, such as a telephone-digit scheme on a letter-group layout whose letters
    /// were all turned into digits, gets no companion for that layout.
    static func hasReachableSpelling(_ projection: SourceProjection, fold: PhysicalFold, compactFold: CompactFold)
        -> Bool
    {
        let ignored = Set(fold.ignoredCharacters)
        let keys = Set(fold.sourceAlphabet).subtracting(ignored)
        let digitsErased = compactFold.isPhoneDigits && erasesSourceDigitSpellings(projection)
        return projection.syllables.contains { syllable in
            syllable.spellings.contains { spelling in
                !spelling.text.isEmpty
                    && spelling.text.allSatisfy { keys.contains($0) && !(digitsErased && $0.isASCII && $0.isNumber) }
            }
        }
    }

    /// Runs before the source's own preedit rules, which then see the letters a tap
    /// would have sent.
    static func addExactTokenPreedit(_ rule: String?, to translator: inout [String: Any]) {
        guard let rule else { return }
        translator["preedit_format"] = [rule] + (translator["preedit_format"] as? [String] ?? [])
    }

    /// A bounded, deterministic deploy-check sample of direct tokens: the first
    /// `limit` tokens (sorted) that are UNIQUELY identified by their own code —
    /// i.e. no other source code in the same fold class has this token as a partial
    /// fold. Those are exactly the tokens the runtime will offer as lockable, so the
    /// native post-deploy verification is deterministic. `nil` when the source has
    /// no such token (the companion then carries no rewrite capability).
    ///
    /// This is linear in the source dictionary's own code inventory (the projection
    /// the engine already produced) — never a cartesian product and never a
    /// per-code alias.
    static func directTokenSample(
        _ projection: SourceProjection, fold compactFold: CompactFold,
        limit: Int = 16
    ) -> [String]? {
        var foldMap = compactFold.map
        // Keep direct-token equivalence identical to the generated derive layer.
        // Uppercase is admitted only as a paired source key by `physicalFold`.
        for (letter, folded) in Array(foldMap) {
            foldMap[Character(String(letter).uppercased())] = folded
        }
        func fold(_ value: String) -> String {
            String(value.map { foldMap[$0] ?? $0 })
        }
        func isPartialFold(_ candidate: String, of code: String) -> Bool {
            guard candidate.count == code.count else { return false }
            for (c, k) in zip(candidate, code) {
                let folded = foldMap[k] ?? k
                if c != k && c != folded { return false }
            }
            return true
        }
        var byFold: [String: [String]] = [:]
        for syllable in projection.syllables { byFold[fold(syllable.token), default: []].append(syllable.token) }
        var sample: [String] = []
        for token in projection.syllables.map(\.token).sorted() {
            let classMembers = (byFold[fold(token)] ?? []).filter {
                isPartialFold(token, of: $0)
            }
            if classMembers.count == 1 { sample.append(token) }
            if sample.count >= max(1, limit) { break }
        }
        return sample.isEmpty ? nil : sample
    }

    /// Builds a `table_translator` compact companion for a table source. Preserves
    /// the source's FULL `engine/translators` list (order and every auxiliary such
    /// as `table_translator@custom_phrase` / `reverse_lookup_translator` /
    /// `lua_translator`), the auxiliary config sections and segmentors verbatim; it
    /// only renames the schema/prism and rewrites the PRIMARY default
    /// `translator` section, then declares the DIRECT rewrite capability.
    ///
    /// The primary producer is the unique DEFAULT (no `@`) table entry — the same
    /// contract `adaptability` and the native `single_producer` use. Auxiliaries are
    /// never the syllabary source and are never deleted to "prove" provenance.
    static func generateTableCompanion(
        compiled: Data, sourceID: String, fold compactFold: CompactFold,
        projection: SourceProjection
    ) throws -> Data {
        guard let fold = physicalFold(sourceAlphabet: projection.alphabet, fold: compactFold) else {
            throw RecipeInstallError.invalidResource("输入方案的字母表无法适配紧凑键盘布局")
        }
        guard compiled.count <= RecipeResourceBudget.sourceFile,
            let text = String(data: compiled, encoding: .utf8),
            var root = try BoundedYAML.load(yaml: text) as? [String: Any],
            var schema = root["schema"] as? [String: Any],
            schema["schema_id"] as? String == sourceID,
            let producer = Self.autoAdaptableProducer(inCompiled: compiled),
            producer.klass == .table,
            var translator = root[producer.namespace] as? [String: Any],
            let dictionary = translator["dictionary"] as? String, !dictionary.isEmpty
        else {
            throw RecipeInstallError.invalidResource("输入方案不是可自动适配的码表配置")
        }
        let target = identifier(sourceID: sourceID, fold: compactFold)
        schema["schema_id"] = target
        schema["name"] = "\(schema["name"] as? String ?? sourceID) · \(compactFold.id)键适配"
        root["schema"] = schema

        // `engine/translators`, the auxiliary config sections and segmentors are
        // left EXACTLY as the source declared them: the compact companion is the same
        // scheme with a folded spelling space, not a stripped-down one. The native
        // `single_producer` ignores named auxiliaries when a default producer exists,
        // so the binding stays exact without deleting anything.
        if translator["user_dict"] == nil { translator["user_dict"] = dictionary }
        translator["prism"] = target
        // Never inherit the source's typo-correction switch on merged/numeric keys.
        if translator[TypoCorrection.configLeaf] != nil { translator[TypoCorrection.configLeaf] = false }
        Self.addExactTokenPreedit(fold.exactTokenPreedit, to: &translator)
        // Post-commit prediction (predictor / predict_translator and their config) is inherited
        // as is: it keys on commits, not on the spelling, so compact input predicts the same.
        root[producer.namespace] = translator

        var algebra = root["speller"].flatMap { ($0 as? [String: Any])?["algebra"] as? [String] } ?? []
        if compactFold.isPhoneDigits && erasesSourceDigitSpellings(projection) {
            algebra.append(sourceDigitSpellingErase)
        }
        algebra.append(contentsOf: fold.rules)
        var speller = (root["speller"] as? [String: Any]) ?? [:]
        speller["algebra"] = algebra
        speller["alphabet"] = fold.typeableAlphabet
        speller["initials"] = fold.typeableAlphabet
        root["speller"] = speller

        // A bare compact-code spelling must reach abc_segmentor, not a recognizer.
        if var recognizer = root["recognizer"] as? [String: Any],
            var patterns = recognizer["patterns"] as? [String: String]
        {
            let keys = fold.typeableAlphabet
            let samples = keys.map(String.init) + [String(keys.prefix(4))]
            for (name, pattern) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    throw RecipeInstallError.invalidResource("无法检查识别规则：\(name)")
                }
                if samples.contains(where: {
                    regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                }) {
                    patterns.removeValue(forKey: name)
                }
            }
            recognizer["patterns"] = patterns
            root["recognizer"] = recognizer
        }
        root.removeValue(forKey: "__build_info")

        let base = Data(try Yams.dump(object: root, sortKeys: true).utf8)
        // No uniquely-identifiable code means no bounded direct lock: fail closed
        // (no rewrite capability) rather than advertising a fake one.
        guard let sample = directTokenSample(projection, fold: compactFold) else {
            return try injectingCapability(
                into: base, adapterSchema: target,
                displayCapability: nil, rewriteCapability: nil)
        }
        // The direct capability is bounded: a versioned lock and
        // a bounded deploy-check sample. No lock_map, no per-code metadata.
        let capability = RewriteCapability(
            version: rewriteWireVersionDirect,
            lock: directTokenLockValue,
            sourceSchema: projection.sourceSchema,
            translatorNamespace: projection.translatorNamespace,
            adapterSchema: target,
            lockMap: [:],
            directTokens: sample)
        return try injectingCapability(
            into: base, adapterSchema: target,
            displayCapability: nil,
            rewriteCapability: capability)
    }
}
