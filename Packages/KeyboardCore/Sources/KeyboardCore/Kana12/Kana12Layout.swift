import Foundation

/// One key of the 4 x 3 kana12 grid (J2.1/J2.2). The left/right columns and the bottom action
/// keys are front-end concerns; only the twelve keys that produce kana or literals live here.
public enum Kana12Key: String, CaseIterable, Sendable {
    case a, ka, sa, ta, na, ha, ma, ya, ra, wa
    /// 標点: tap 、 left 。 up ？ right ！ down … (J2.2).
    case punctuation
    /// 小゛゜: replaces the previous kana of this composition with its next variant (J2.4).
    case modifier
}

/// Flick direction relative to the pressed key; a tap is the あ段 glyph.
public enum Kana12FlickDirection: String, CaseIterable, Sendable {
    case tap, left, up, right, down
}

/// What a grid cell produces. Literals are inserted by the front end as text; they are never
/// forged into Rime key tokens, because the schema key map does not define them.
public enum Kana12KeyOutput: Equatable, Sendable {
    case kana(String)
    case literal(String)
}

/// Static J2 grid, tap cycles and 小゛゜ variant chains.
public enum Kana12Layout {
    /// J2.2: tap = あ段, left = い段, up = う段, right = え段, down = お段. The や and 標点 rows
    /// put brackets/punctuation on the sides exactly as J2.2 lists them. わ行 has no down glyph
    /// in J2, and the frozen data's only extra candidate (～) has no verified code, so わ has no
    /// down output instead of inventing one.
    private static let outputs: [Kana12Key: [Kana12FlickDirection: Kana12KeyOutput]] = [
        .a: [
            .tap: .kana("あ"), .left: .kana("い"), .up: .kana("う"), .right: .kana("え"), .down: .kana("お"),
        ],
        .ka: [
            .tap: .kana("か"), .left: .kana("き"), .up: .kana("く"), .right: .kana("け"), .down: .kana("こ"),
        ],
        .sa: [
            .tap: .kana("さ"), .left: .kana("し"), .up: .kana("す"), .right: .kana("せ"), .down: .kana("そ"),
        ],
        .ta: [
            .tap: .kana("た"), .left: .kana("ち"), .up: .kana("つ"), .right: .kana("て"), .down: .kana("と"),
        ],
        .na: [
            .tap: .kana("な"), .left: .kana("に"), .up: .kana("ぬ"), .right: .kana("ね"), .down: .kana("の"),
        ],
        .ha: [
            .tap: .kana("は"), .left: .kana("ひ"), .up: .kana("ふ"), .right: .kana("へ"), .down: .kana("ほ"),
        ],
        .ma: [
            .tap: .kana("ま"), .left: .kana("み"), .up: .kana("む"), .right: .kana("め"), .down: .kana("も"),
        ],
        .ya: [
            .tap: .kana("や"), .left: .literal("（"), .up: .kana("ゆ"), .right: .literal("）"),
            .down: .kana("よ"),
        ],
        .ra: [
            .tap: .kana("ら"), .left: .kana("り"), .up: .kana("る"), .right: .kana("れ"), .down: .kana("ろ"),
        ],
        .wa: [
            .tap: .kana("わ"), .left: .kana("を"), .up: .kana("ん"), .right: .kana("ー"),
        ],
        .punctuation: [
            .tap: .literal("、"), .left: .literal("。"), .up: .literal("？"), .right: .literal("！"),
            .down: .literal("…"),
        ],
        .modifier: [:],
    ]

    /// J2.3: tapping the same key repeatedly within the toggle window walks this list and wraps.
    /// It is the row's five 段 kana first, then the row's variants in the same order (small
    /// vowels for あ/や, dakuten for か/さ/た/は, then handakuten for は). つ keeps the row
    /// variant づ here; the 小゛゜ key walks つ -> っ -> づ instead. ゎ is a variant of わ, so it
    /// closes the わ row list after ー.
    private static let toggleCycles: [Kana12Key: [String]] = [
        .a: ["あ", "い", "う", "え", "お", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"],
        .ka: ["か", "き", "く", "け", "こ", "が", "ぎ", "ぐ", "げ", "ご"],
        .sa: ["さ", "し", "す", "せ", "そ", "ざ", "じ", "ず", "ぜ", "ぞ"],
        .ta: ["た", "ち", "つ", "て", "と", "だ", "ぢ", "づ", "で", "ど"],
        .na: ["な", "に", "ぬ", "ね", "の"],
        .ha: ["は", "ひ", "ふ", "へ", "ほ", "ば", "び", "ぶ", "べ", "ぼ", "ぱ", "ぴ", "ぷ", "ぺ", "ぽ"],
        .ma: ["ま", "み", "む", "め", "も"],
        .ya: ["や", "ゆ", "よ", "ゃ", "ゅ", "ょ"],
        .ra: ["ら", "り", "る", "れ", "ろ"],
        .wa: ["わ", "を", "ん", "ー", "ゎ"],
        .punctuation: [],
        .modifier: [],
    ]

    /// J2.4: the 小゛゜ chain for every reachable kana. Each array is a closed cycle; kana that
    /// never react to the modifier are absent (な/ま/ら rows, を, ん, ー).
    private static let variantCycles: [[String]] = [
        ["あ", "ぁ"], ["い", "ぃ"], ["う", "ぅ"], ["え", "ぇ"], ["お", "ぉ"],
        ["か", "が"], ["き", "ぎ"], ["く", "ぐ"], ["け", "げ"], ["こ", "ご"],
        ["さ", "ざ"], ["し", "じ"], ["す", "ず"], ["せ", "ぜ"], ["そ", "ぞ"],
        ["た", "だ"], ["ち", "ぢ"], ["つ", "っ", "づ"], ["て", "で"], ["と", "ど"],
        ["は", "ば", "ぱ"], ["ひ", "び", "ぴ"], ["ふ", "ぶ", "ぷ"], ["へ", "べ", "ぺ"], ["ほ", "ぼ", "ぽ"],
        ["や", "ゃ"], ["ゆ", "ゅ"], ["よ", "ょ"], ["わ", "ゎ"],
    ]

    private static let variantSuccessors: [String: String] = {
        var successors: [String: String] = [:]
        for cycle in variantCycles {
            for (index, kana) in cycle.enumerated() {
                successors[kana] = cycle[(index + 1) % cycle.count]
            }
        }
        return successors
    }()

    /// The cell output, or nil when the direction has no glyph.
    public static func output(for key: Kana12Key, direction: Kana12FlickDirection) -> Kana12KeyOutput? {
        outputs[key]?[direction]
    }

    /// The kana of a cell, or nil when the cell is a literal or empty.
    public static func kana(for key: Kana12Key, direction: Kana12FlickDirection) -> String? {
        guard case .kana(let kana)? = output(for: key, direction: direction) else { return nil }
        return kana
    }

    /// The literal of a cell, or nil when the cell is kana or empty.
    public static func literal(for key: Kana12Key, direction: Kana12FlickDirection) -> String? {
        guard case .literal(let literal)? = output(for: key, direction: direction) else { return nil }
        return literal
    }

    /// The repeated-tap walk for a key; empty for keys the model does not tap-cycle.
    public static func toggleCycle(for key: Kana12Key) -> [String] {
        toggleCycles[key] ?? []
    }

    /// The kana the 小゛゜ key turns the given kana into, or nil when it has no variant.
    public static func nextVariant(of kana: String) -> String? {
        variantSuccessors[kana]
    }
}
