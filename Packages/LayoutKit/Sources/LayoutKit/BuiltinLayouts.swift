import Foundation

/// Independently authored layout data, also available as editable JSON in Resources/Layouts.
public enum BuiltinLayouts {
    public static let all: [LayoutDefinition] = [
        qwerty26, merged14, merged18, phone9, zhuyin41, cangjie26, romaji26, kana12,
    ]

    public static let qwerty26 = LayoutDefinition(
        id: "qwerty26", name: "26 键", input: .init(builtinLayout: .qwerty26),
        rows: alphabetRows() + [controls])

    /// The definition with the hand cuts it is drawn with written into its split, for a copy: the
    /// copy has its own id and name, so it would no longer count as the bundled layout and would
    /// draw middle cuts instead of what the editor showed.
    public static func persistingHandCuts(in definition: LayoutDefinition) -> LayoutDefinition {
        handSplit(for: definition).map(definition.settingSplit) ?? definition
    }

    /// Row cuts of the standard 26-key letter rows (10, 9 and 7 letters): five keys on the left.
    public static let standardLetterRowBreaks = [5, 5, 5]

    /// Where the unedited bundled 26- and 18-key layouts split when nothing saved says otherwise:
    /// each hand keeps its letters from a physical keyboard, QWERT ASDFG ZXCVB on the left (on 18
    /// keys three, three and four keys, the BN pair following its B). The cuts live here rather than
    /// on the definitions so a layout copied from them is not tied to them; a copy gets them written
    /// into its own split (`persistingHandCuts(in:)`). 26 keys stays whole
    /// (`off`) until the user turns splitting on. The cuts count letter keys: the key area draws
    /// Shift and Delete outside the rows, so nothing needs to move. Nil for any other layout, for
    /// one that differs from the bundled one in anything but its split (a renamed copy included),
    /// and for a split with saved cuts.
    public static func handSplit(for definition: LayoutDefinition) -> LayoutSplitConfiguration? {
        let breaks: [Int]
        let layout: LayoutInput.Builtin
        switch definition.input.builtinLayout {
        case .some(.qwerty26): (layout, breaks) = (.qwerty26, standardLetterRowBreaks)
        case .some(.merged18): (layout, breaks) = (.merged18, [3, 3, 4])
        default: return nil
        }
        let bundled = preset(for: layout)
        // The split is what this rule decides, and the note is prose a later release may reword: a
        // changed note must not drop the cuts of a copy the user already stored.
        let comparable = LayoutDefinition(
            id: definition.id, name: definition.name, input: definition.input, rows: definition.rows,
            auxiliaryAreas: definition.auxiliaryAreas, note: bundled.note,
            longPressDelay: definition.longPressDelay, candidateArea: definition.candidateArea,
            split: bundled.split)
        guard comparable == bundled, definition.split?.rowBreaks.isEmpty ?? true else { return nil }
        var split = definition.split ?? LayoutSplitConfiguration(activation: .off)
        split.rowBreaks = breaks
        return split
    }

    public static let merged14 = LayoutDefinition(
        id: "merged14", name: "14 键", input: .init(builtinLayout: .merged14),
        rows: mergedRows([
            ["qw", "er", "ty", "ui", "op"], ["as", "df", "gh", "jk", "l"],
            ["zx", "cv", "bn", "m"],
        ]) + [controls],
        note: "两个字母合用一个键，轻点输入。输入方案支持时，向左或向右滑动可只输入左边或右边的字母。",
        // Wide surfaces split by default so both thumbs reach the merged pairs; a saved split,
        // including an explicit off, stays authoritative and is never migrated back on.
        split: LayoutSplitConfiguration())

    /// Every key must be easy to hit, single letters included. Two-unit pairs would leave
    /// the singles as the narrowest caps on the pad (about 38 pt on a 420 pt phone), so pairs
    /// give width back: 1.7 units against 1.3, caps about 1.33 : 1, close to the widely shared
    /// 18-key skin for Baidu's keyboard (stock Chinese keyboards ship no 18-key pad). Pairs
    /// stay wider because one cap carries two letters and the sideways swipe. All upper-row
    /// singles and pairs share one width each, so row 2 (9.0 units) sits centered under row 1
    /// (10.3) half a single key in from each side, the same stagger as 26-key A under Q.
    public static let merged18 = LayoutDefinition(
        id: "merged18", name: "18 键", input: .init(builtinLayout: .merged18),
        rows: mergedRows(
            [
                ["q", "we", "rt", "y", "u", "io", "p"], ["a", "sd", "fg", "h", "jk", "l"],
                ["z", "xc", "v", "bn", "m"],
            ], singleWidth: 1.3, pairWidth: 1.7) + [controls],
        note: "部分键由两个字母合用，轻点输入。输入方案支持时，向左或向右滑动可只输入左边或右边的字母。",
        // Same wide-surface default as 14-key; qwerty26 and phone9 keep their layout default.
        split: LayoutSplitConfiguration())

    public static let phone9 = LayoutDefinition(
        id: "phone9", name: "9 键", input: .init(builtinLayout: .phone9),
        rows: [
            // Corner badge 1 + long-press 1 (like 2-9), so editors show the key that really runs.
            LayoutRow(keys: [
                LayoutKey(
                    label: "，。？", secondaryLabel: t9DigitOne,
                    action: .init(.literal, value: "，"),
                    longPress: [literalOption(t9DigitOne)]),
                phone("ABC", "2"), phone("DEF", "3"),
            ]),
            LayoutRow(keys: [phone("GHI", "4"), phone("JKL", "5"), phone("MNO", "6")]),
            LayoutRow(keys: [phone("PQRS", "7"), phone("TUV", "8"), phone("WXYZ", "9")]),
            LayoutRow(keys: [
                LayoutKey(label: "布局", action: .init(.modeSwitch, value: "nextLayout")),
                LayoutKey(label: "空格", width: 4, action: .init(.space)),
                LayoutKey(label: "🌐", action: .init(.globe)),
            ]),
        ],
        auxiliaryAreas: [
            .init(
                position: .trailing, role: .editing,
                keys: [
                    LayoutKey(label: "⌫", action: .init(.backspace)),
                    LayoutKey(label: "分词", action: .init(.code, value: "'")),
                    LayoutKey(label: "⏎", action: .init(.enter)),
                ]),
            .init(position: .leading, role: .disambiguation),
        ], note: phone9Note)

    /// Shown to users (resource inspector, layout manager), so it must match real behavior.
    private static let phone9Note = "2–9 键按所选的输入方案输入。输入中轻点首键可分词；未输入时，左栏前三个符号可直接输入，连续点按首键可轮换其余符号。长按首键输入 1，长按 2–9 输入对应数字。"

    /// Ordered quick symbols: saved order first, missing items filled from the default sequence, full-width
    /// mapped to half-width in ASCII mode, then de-duplicated after mapping (first occurrence decides rank),
    /// with the original first-key address/URL marks appended as a low-frequency tail.
    ///
    /// This is the single ordering source for both the leading rail (first three) and the first-key cycle
    /// (4th item on), so titles, accessibility hints and actual insertion order cannot disagree; the two
    /// partition the list with no overlap or gap.
    ///
    /// The tail keeps `@ / . : _ -` reachable from the first key: they are not in the default
    /// quick-bar set and would otherwise lose their entry point; de-duplication keeps them from repeating
    /// earlier items.
    public static func t9QuickSymbolValues(saved: String, ascii: Bool) -> [String] {
        let userOrdered = (saved + T9QuickSymbolStore.defaultSymbols).map { character -> String in
            let value = String(character)
            guard ascii else { return value }
            return t9ASCIIPunctuation[value] ?? value
        }
        var seen = Set<String>()
        return (userOrdered + t9PunctuationSymbols()).filter { seen.insert($0).inserted }
    }

    /// Resolves a phone9 override before applying the shared ordering and ASCII conversion.
    public static func t9QuickSymbolValues(
        for definition: LayoutDefinition, inherited: String, ascii: Bool
    ) -> [String] {
        guard PhoneKeypadStructure.matches(definition) else { return [] }
        return t9QuickSymbolValues(saved: definition.t9QuickSymbols ?? inherited, ascii: ascii)
    }

    /// The first three items typed directly by the leading rail, top to bottom.
    public static func t9QuickRailValues(saved: String, ascii: Bool) -> [String] {
        Array(t9QuickSymbolValues(saved: saved, ascii: ascii).prefix(3))
    }

    /// From the 4th item on: cycled by repeated taps on the first key of the main area.
    public static func t9QuickCycleValues(saved: String, ascii: Bool) -> [String] {
        Array(t9QuickSymbolValues(saved: saved, ascii: ascii).dropFirst(3))
    }

    /// Full-width to half-width punctuation. Used only in ASCII mode; Chinese mode keeps the user's characters.
    ///
    /// Covers every full-width mark the quick bar can hold (including `：；【】`); a missing mapping would put
    /// full-width characters into ASCII fields, and the manager's default sequence is `，。？！、…：；（）【】`.
    private static let t9ASCIIPunctuation: [String: String] = [
        "，": ",", "、": ",", "。": ".", "？": "?", "！": "!", "…": "...",
        "（": "(", "）": ")", "：": ":", "；": ";", "【": "[", "】": "]",
    ]

    /// Whether a builtin 9-key digit key (2-9) should take the layout's declared alternates (long-press types the digit).
    ///
    /// A digit key is `label:"ABC"` (cap) + `.code("2")` (tap sends the digit code) + `longPress:[literal "2"]`.
    /// `AlternateKeyPolicy` follows letter-page semantics and returns empty when `keyLabel` is not a single
    /// letter (neither `"2"` nor `"ABC"` qualifies), which would drop the declared long-press, so these keys
    /// must take the declared path.
    ///
    /// Only digit-code keys qualify: control keys, auxiliary keys, letter keys and DIY definitions do not,
    /// and the fixed letter menu stays closed.
    public static func t9DigitKeyUsesDeclaredAlternates(_ key: LayoutKey) -> Bool {
        guard key.action.type == .code, let value = key.action.value,
            value.count == 1, ("2"..."9").contains(value)
        else { return false }
        // Without declared long-press alternates, fall back to the generic policy.
        return !(key.longPress ?? []).isEmpty
    }

    /// The idle first key cycles the address/URL marks of the system 9-key's
    /// 「@/.」 key. Sentence punctuation lives in the leading rail; repeating it
    /// here (and in a bottom 「。」) made three copies of the same three marks.
    ///
    /// Kept as a fallback: only when the ordered list has nothing from the 4th item on (unreachable with the
    /// current default sequence) does the first key fall back to these address marks instead of becoming a dead key.
    public static func t9PunctuationSymbols() -> [String] {
        ["@", "/", ".", ":", "_", "-"]
    }

    /// Cap and action of the first key, derived from the cycle order: the label is the first three
    /// values and tap inserts the first. Returns nil for an empty array (caller decides the fallback),
    /// never a key that looks usable but is not.
    ///
    /// Long-press matches 2-9: a single `1` (corner badge + long-press input). Cycling applies to taps only.
    public static func t9CycleKey(_ values: [String]) -> LayoutKey? {
        guard let first = values.first, !first.isEmpty else { return nil }
        return LayoutKey(
            label: values.prefix(3).joined(), secondaryLabel: t9DigitOne,
            action: .init(.literal, value: first),
            longPress: [literalOption(t9DigitOne)])
    }

    /// Long-press digit shared by the first key and 2-9.
    public static let t9DigitOne = "1"

    /// Last-resort first key built from the address-mark fallback: label is the first three marks, tap inserts the first.
    public static func t9PunctuationKey() -> LayoutKey {
        let marks = t9PunctuationSymbols()
        return LayoutKey(label: marks.prefix(3).joined(), action: .init(.literal, value: marks[0]))
    }

    /// First key while composing: tap still separates syllables (sends apostrophe); long-press types `1` like 2-9.
    /// It is a plain literal action, so it commits the composition first, then inserts the digit,
    /// and never triggers cycling or separation.
    public static func t9SeparatorKey() -> LayoutKey {
        LayoutKey(
            label: "分词", secondaryLabel: t9DigitOne,
            action: .init(.code, value: "'"),
            longPress: [literalOption(t9DigitOne)])
    }

    /// Idle-only, ordered defaults. The live builtin lets users replace each slot;
    /// composing uses provenance-checked candidate reading choices instead.
    public static func t9LeadingShortcuts(ascii: Bool) -> [LayoutKey] {
        Array(ascii ? "@/-()_" : "@/-()…").map { character in
            let value = String(character)
            return LayoutKey(label: value, action: .init(.literal, value: value))
        }
    }

    // MARK: - 123 / symbol page bilingual pairs

    /// The Chinese/ASCII branch pair for one page slot. It is the same *position* in the two
    /// existing key tables, not a punctuation translation: `、`/`?` and `@`/`&` stay the two
    /// explicitly authored versions of that slot.
    struct BilingualPageMark: Equatable, Sendable {
        let chinese: String
        let ascii: String
    }

    /// Numeric 123 slots paired by position across the two existing canonical tables.
    static func numericPageBilingualRows() -> [[BilingualPageMark]] {
        pairRows(numericPageRows(ascii: false), numericPageRows(ascii: true))
    }

    /// Row-shaped symbol slots paired by position across the two existing canonical tables.
    static func symbolPageBilingualRows() -> [[BilingualPageMark]] {
        pairRows(symbolPageRows(ascii: false), symbolPageRows(ascii: true))
    }

    private static func pairRows(_ chinese: [[String]], _ ascii: [[String]]) -> [[BilingualPageMark]] {
        guard chinese.count == ascii.count else { return [] }
        return zip(chinese, ascii).map { chineseRow, asciiRow in
            zip(chineseRow, asciiRow).map { BilingualPageMark(chinese: $0, ascii: $1) }
        }
    }

    /// The real 123 punctuation rail order: period/question/exclamation first, then the last and
    /// second numeric rows, de-duplicated by the branch's actual strings (first occurrence wins).
    /// The shared runtime rail and a copied digit pad both read this single source.
    public static func phoneNumericRailValues(ascii: Bool) -> [String] {
        let priority = ascii ? [".", "?", "!"] : [".", "？", "！"]
        let rows = numericPageRows(ascii: ascii)
        // The row pages type the comma from the bottom row; the digit pad has none, so the rail
        // keeps it right after the period as before.
        var last = rows.last ?? []
        last.insert(ascii ? "," : "，", at: min(1, last.count))
        let rest = last + (rows.count > 1 ? rows[1] : [])
        var seen = Set<String>()
        return (priority + rest).filter { seen.insert($0).inserted }
    }

    // MARK: - 123 / symbol page rows

    /// The 123 page: digits, then the everyday marks, so what most text needs is one tap from the
    /// letters. Nothing here repeats on the #+= page, which holds the rest one page deeper (the
    /// comma is in the bottom row).
    public static func numericPageRows(ascii: Bool) -> [[String]] {
        ascii
            ? [
                Array("1234567890").map(String.init),
                Array("-/:;()$&@\"").map(String.init),
                [".", "?", "!", "'", "%", "#", "+"],
            ]
            : [
                Array("1234567890").map(String.init),
                ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"],
                ["。", "？", "！", "、", "…", ".", "%"],
            ]
    }

    /// The row-shaped symbol page: the 123 page's geometry with the less frequent marks, none of
    /// which is also on the 123 page.
    public static func symbolPageRows(ascii: Bool) -> [[String]] {
        ascii
            ? [
                Array("[]{}*=\\€£¥").map(String.init),
                ["•", "°", "§", "×", "÷", "±", "≈", "≠", "©", "™"],
                ["<", ">", "~", "`", "^", "_", "|"],
            ]
            : [
                ["【", "】", "{", "}", "#", "^", "*", "+", "=", "&"],
                ["_", "——", "\\", "|", "～", "《", "》", "「", "」", "·"],
                ["$", "€", "£", "<", ">", "‘", "’"],
            ]
    }

    private static let controls = LayoutRow(keys: [
        LayoutKey(label: "布局", action: .init(.modeSwitch, value: "nextLayout")),
        LayoutKey(label: "🌐", action: .init(.globe)),
        LayoutKey(label: "空格", width: 4, action: .init(.space)),
        LayoutKey(label: "⌫", action: .init(.backspace)),
        LayoutKey(label: "⏎", action: .init(.enter)),
    ])

    private static func literalOption(_ value: String) -> LayoutOption {
        LayoutOption(label: value, action: .init(.literal, value: value))
    }

    private static func phone(_ letters: String, _ digit: String) -> LayoutKey {
        LayoutKey(
            label: letters, secondaryLabel: digit, action: .init(.code, value: digit),
            longPress: [literalOption(digit)])
    }

    private static func mergedRows(
        _ groups: [[String]], singleWidth: Double? = nil, pairWidth: Double? = nil
    ) -> [LayoutRow] {
        groups.map { row in
            LayoutRow(keys: row.map { mergedKey($0, width: $0.count > 1 ? pairWidth : singleWidth) })
        }
    }

    /// Real long-press alternates for merged keys: the main key sends the cluster representative and
    /// long-press types the rest of the cluster (the second letter of qm/er/ty/...); single-letter keys
    /// (l/m) get common punctuation. Same long-press path as the 26-key digits/symbols.
    private static func mergedKey(_ group: String, width: Double?) -> LayoutKey {
        let partnerOptions = group.dropFirst().map { literalOption(String($0)) }
        let punctuationOptions: [LayoutOption]
        if group == "l" {
            punctuationOptions = [literalOption("，")]
        } else if group == "m" {
            punctuationOptions = [literalOption("。")]
        } else {
            punctuationOptions = []
        }
        var options = partnerOptions + punctuationOptions
        if group == "qw" { options += [literalOption("1"), literalOption("!")] }
        return LayoutKey(
            label: group.uppercased(),
            secondaryLabel: group == "qw" ? "1 !" : (group.count > 1 ? "合并键" : nil),
            width: width,
            action: .init(.code, value: String(group.prefix(1))),
            longPress: options.isEmpty ? nil : options)
    }

    private static func alphabetRows() -> [LayoutRow] {
        let digits = Dictionary(uniqueKeysWithValues: zip("qwertyuiop".map(String.init), "1234567890".map(String.init)))
        return ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { letters in
            LayoutRow(
                keys: letters.map { letter in
                    let value = String(letter)
                    return LayoutKey(
                        label: value, secondaryLabel: digits[value],
                        action: .init(.code, value: value),
                        longPress: AlternateKeyPolicy.defaultLetterLiterals(for: value).map(literalOption))
                })
        }
    }

    // MARK: - Traditional Chinese boards

    /// The 大千 (Daqian) 41-key board: four letter rows of 11 / 10 / 10 / 10 caps. A cap draws the
    /// bopomofo symbol and sends the ASCII key that symbol sits on, which is the code the scheme's
    /// own keymap expects; the codes never appear on a cap. The space bar sends the first tone.
    public static let zhuyin41 = LayoutDefinition(
        id: "zhuyin41", name: "注音 41 键",
        // The encoding kind stays the 26-key one: the board is a layout of its own, identified by
        // its id, so no new kind and no new engine case come with it.
        input: .init(builtinLayout: .qwerty26),
        rows: zhuyinLetterRows() + [zhuyinControlRow])

    private static let zhuyinKeys: [[(cap: String, code: String)]] = [
        [
            ("ㄅ", "1"), ("ㄉ", "2"), ("ˇ", "3"), ("ˋ", "4"), ("ㄓ", "5"), ("ˊ", "6"), ("˙", "7"),
            ("ㄚ", "8"), ("ㄞ", "9"), ("ㄢ", "0"), ("ㄦ", "-"),
        ],
        [
            ("ㄆ", "q"), ("ㄊ", "w"), ("ㄍ", "e"), ("ㄐ", "r"), ("ㄔ", "t"), ("ㄗ", "y"), ("ㄧ", "u"),
            ("ㄛ", "i"), ("ㄟ", "o"), ("ㄣ", "p"),
        ],
        [
            ("ㄇ", "a"), ("ㄋ", "s"), ("ㄎ", "d"), ("ㄑ", "f"), ("ㄕ", "g"), ("ㄘ", "h"), ("ㄨ", "j"),
            ("ㄜ", "k"), ("ㄠ", "l"), ("ㄤ", ";"),
        ],
        [
            ("ㄈ", "z"), ("ㄌ", "x"), ("ㄏ", "c"), ("ㄒ", "v"), ("ㄖ", "b"), ("ㄙ", "n"), ("ㄩ", "m"),
            ("ㄝ", ","), ("ㄡ", "."), ("ㄥ", "/"),
        ],
    ]

    private static func zhuyinLetterRows() -> [LayoutRow] {
        zhuyinKeys.map { row in
            LayoutRow(keys: row.map { LayoutKey(label: $0.cap, action: .init(.code, value: $0.code)) })
        }
    }

    /// The controls a 41-key board draws itself: its four letter rows take the whole width, so no
    /// shell key surrounds them. Every face is automatic, so traditional input reads 空白 and the
    /// live Return title. Delete stays here because no shell row slot is left for it.
    private static let zhuyinControlRow = LayoutRow(keys: [
        LayoutKey(label: "🌐", action: .init(.globe), titleMode: .automatic),
        LayoutKey(label: "123", action: .pageSwitch(.numeric), titleMode: .automatic),
        LayoutKey(label: "中/英", action: .languageSwitch(), titleMode: .automatic),
        LayoutKey(label: "空格", width: 4, action: .init(.space), titleMode: .automatic),
        LayoutKey(label: "⌫", action: .init(.backspace), titleMode: .automatic),
        LayoutKey(label: "⏎", action: .init(.enter), titleMode: .automatic),
    ])

    /// The 倉頡 (Cangjie) 26-key board: the letters keep their QWERTY positions, each cap draws the
    /// radical its letter stands for and the corner label is the letter itself. The fourth row is
    /// the 26-key stand-in, so the keyboard draws the same footer as every 26-key board, with the
    /// punctuation keys either side of the space bar.
    public static let cangjie26 = LayoutDefinition(
        id: "cangjie26", name: "仓颉 26 键",
        input: .init(builtinLayout: .qwerty26),
        rows: cangjieLetterRows() + [controls])

    private static let cangjieKeys: [[(letter: String, radical: String)]] = [
        [
            ("q", "手"), ("w", "田"), ("e", "水"), ("r", "口"), ("t", "廿"), ("y", "卜"), ("u", "山"),
            ("i", "戈"), ("o", "人"), ("p", "心"),
        ],
        [
            ("a", "日"), ("s", "尸"), ("d", "木"), ("f", "火"), ("g", "土"), ("h", "竹"), ("j", "十"),
            ("k", "大"), ("l", "中"),
        ],
        [("z", "重"), ("x", "難"), ("c", "金"), ("v", "女"), ("b", "月"), ("n", "弓"), ("m", "一")],
    ]

    private static func cangjieLetterRows() -> [LayoutRow] {
        cangjieKeys.map { row in
            LayoutRow(
                keys: row.map { key in
                    LayoutKey(
                        label: key.radical, secondaryLabel: key.letter.uppercased(),
                        action: .init(.code, value: key.letter))
                })
        }
    }

    // MARK: - Japanese board

    /// The Japanese romaji board: the QWERTY 26-key letters with ー right of M. The board keeps the
    /// 26-key encoding kind and is identified by its id, so no new kind and no new engine case come
    /// with it. The fourth row is the 26-key stand-in: while it is unedited the keyboard draws its
    /// own footer, which names the space, Return and language keys for the input language and puts
    /// 、 and 。 on either side of the space bar.
    public static let romaji26 = LayoutDefinition(
        id: "romaji26", name: "罗马字 26 键",
        input: .init(builtinLayout: .qwerty26),
        rows: romajiRows() + [controls])

    /// ー sends the scheme's minus code, the key the romaji spelling uses for a long vowel; a
    /// literal ー would bypass the scheme's own punctuation handling.
    private static let longVowelKey = LayoutKey(label: "ー", action: .init(.code, value: "-"))

    /// The bundled letter rows with ー appended to the third row. Keeping the bundled letter menus
    /// lets the input language rename their marks (a Japanese board offers 、 。 「 」 and ー).
    private static func romajiRows() -> [LayoutRow] {
        var rows = alphabetRows()
        rows[2] = LayoutRow(keys: rows[2].keys + [longVowelKey])
        return rows
    }

    /// The Japanese twelve-key (kana12) board: the 4 x 3 kana grid between a leading rail
    /// (composition caret left, 記号, あ/A, the system keyboard switch) and a trailing rail
    /// (delete, space, Return spanning the lower two rows). The grid carries the tap key of each
    /// row only: flick and repeated-tap targets belong to the kana input model, so a cap names its
    /// row and the handler spells that row's kana into the engine. Because the fourth row types
    /// kana it is content, not a control row, so neither the 26-key Shift/Delete chrome nor the
    /// automatic footer is drawn over the grid; the leading rail's globe is the only keyboard
    /// switch, which keeps the four rows intact.
    public static let kana12 = LayoutDefinition(
        id: "kana12", name: "假名 12 键",
        input: .init(builtinLayout: .qwerty26),
        rows: kana12Rows(),
        auxiliaryAreas: [kana12LeadingRail, kana12TrailingRail])

    /// あ か さ / た な は / ま や ら: the tap glyph of each row with the row id the kana handler
    /// turns into romaji.
    private static let kana12Grid: [[(cap: String, rowID: String)]] = [
        [("あ", "a"), ("か", "ka"), ("さ", "sa")],
        [("た", "ta"), ("な", "na"), ("は", "ha")],
        [("ま", "ma"), ("や", "ya"), ("ら", "ra")],
    ]

    /// 小゛゜ わ 、。?!: the modifier edits the kana just typed, わ taps its row, and 標点 types its
    /// tap mark (。 ？ ！ … are flick targets of the kana model).
    private static let kana12BottomRow = LayoutRow(keys: [
        LayoutKey(label: "小゛゜", action: .kanaModifier),
        LayoutKey(label: "わ", action: .kana("wa")),
        LayoutKey(label: "、。?!", action: .init(.literal, value: "、")),
    ])

    private static func kana12Rows() -> [LayoutRow] {
        kana12Grid.map { row in
            LayoutRow(keys: row.map { LayoutKey(label: $0.cap, action: .kana($0.rowID)) })
        } + [kana12BottomRow]
    }

    /// Four keys, one per grid row. Every face is automatic, so the board reads 記号 and あ/A for
    /// Japanese; only the named caret key keeps its stored face because no control draws it.
    private static let kana12LeadingRail = LayoutAuxiliaryArea(
        position: .leading, role: .editing,
        keys: [
            LayoutKey(label: "←", action: .cursorLeft),
            LayoutKey(label: "記号", action: .pageSwitch(.symbols), titleMode: .automatic),
            LayoutKey(label: "あ/A", action: .languageSwitch(), titleMode: .automatic),
            LayoutKey(label: "🌐", action: .init(.globe), titleMode: .automatic),
        ])

    /// Delete, space and Return; Return's span is two rows, the existing rail width field, so the
    /// rail covers the same four rows as the grid without a height metadata of its own.
    private static let kana12TrailingRail = LayoutAuxiliaryArea(
        position: .trailing, role: .editing,
        keys: [
            LayoutKey(label: "⌫", action: .init(.backspace), titleMode: .automatic),
            LayoutKey(label: "空格", action: .init(.space), titleMode: .automatic),
            LayoutKey(label: "⏎", width: 2, action: .init(.enter), titleMode: .automatic),
        ])
}

// MARK: - Bundled shell identity

public extension BuiltinLayouts {
    /// The bundled layout of one keyboard shape.
    static func preset(for layout: LayoutInput.Builtin) -> LayoutDefinition {
        switch layout {
        case .qwerty26: return qwerty26
        case .merged14: return merged14
        case .merged18: return merged18
        case .phone9: return phone9
        }
    }

    /// The bundled 9-key whose first key may show its live face (the cycling symbols, or 分词
    /// while composing) and hints: quick symbols are enabled, the chrome is the preset's, and the
    /// first key's own face is unedited. The live title replaces the stored one, so an edited
    /// first-key face is shown as authored instead of being covered up; edits to other keys do
    /// not matter here.
    static func matchesPhone9LiveFirstKey(_ definition: LayoutDefinition) -> Bool {
        guard usesPhone9QuickSymbols(definition), matchesPhone9Chrome(definition),
            let key = definition.rows.first?.keys.first, let preset = phone9.rows.first?.keys.first
        else { return false }
        return key.label == preset.label && key.secondaryLabel == preset.secondaryLabel
            && key.titleMode == preset.titleMode
    }

    /// Shared by previews and runtime so an explicit custom comma remains an ordinary action.
    static func usesPhone9QuickSymbols(_ definition: LayoutDefinition) -> Bool {
        guard PhoneKeypadStructure.matches(definition) else { return false }
        switch definition.t9FirstKeyBehavior {
        case .quickSymbols: return true
        case .custom: return false
        case nil: return matchesPhone9PrimarySemantics(definition)
        }
    }

    /// Pure primary-gesture semantics for the known bundled 9-key.
    ///
    /// Only the known input metadata, the three main rows' geometry and their primary actions are
    /// read: label/secondary/title/long-press edits are face metadata, and both the control row and
    /// the side rails are outside the gesture semantics. That keeps first-key cycling, digit
    /// up-flick and declared-alternate behavior alive after metadata edits without ever gating the
    /// injected shell chrome (the chrome uses matchesPhone9Chrome, which rejects control/rail
    /// edits). Unknown schemas and other builtin layouts stay false.
    static func matchesPhone9PrimarySemantics(_ definition: LayoutDefinition) -> Bool {
        definition.input == phone9.input && mainRowsMatch(definition, phone9)
    }

    /// The bundled 9-key's chrome (quick-symbol rail, fixed editing rail and control row) only
    /// replaces declarations that are still the preset's: the side rails and the stand-in control
    /// row. The main keys are drawn from the definition, so edited faces and long-press menus keep
    /// the chrome; their own native behaviour (the live first key) is gated by
    /// `matchesPhone9LiveFirstKey(_:)`. A main area that is no longer a telephone keypad leaves the
    /// phone shell altogether.
    static func matchesPhone9Chrome(_ definition: LayoutDefinition) -> Bool {
        definition.input == phone9.input
            && definition.rows.count == phone9.rows.count
            && definition.auxiliaryAreas == phone9.auxiliaryAreas
            && definition.rows.last == phone9.rows.last
            && PhoneKeypadStructure.matches(definition)
    }

    /// Main-shell identity for the bundled 26/14/18-key: still the known input with the preset's
    /// side areas, three non-empty main rows and at most a non-encoding fourth row, so the shell
    /// can add Shift/Delete (26) or the separator/Delete (14/18) around them. Every main key is
    /// drawn from the definition, so what a key types, its face and its long-press menu are free;
    /// an edit there must not cost the layout its Delete or its bottom row. Whether the 26-key
    /// letters keep the standard columns is `matchesMainShellColumns(_:as:)`; the control row is
    /// `matchesControlRowPolicy(_:as:)`.
    static func matchesMainShell(_ definition: LayoutDefinition, as layout: LayoutInput.Builtin) -> Bool {
        let preset = preset(for: layout)
        let count = PhoneKeypadMetrics.mainRowCount
        guard definition.input == preset.input, definition.auxiliaryAreas == preset.auxiliaryAreas,
            definition.rows.count == count || definition.rows.count == count + 1,
            definition.rows.prefix(count).allSatisfy({ !$0.keys.isEmpty })
        else { return false }
        // The shells draw only the main rows. A fourth row must still be a non-encoding control
        // row; an encoding row would be silently dropped by the shell, so fall back instead.
        return definition.rows.dropFirst(count).allSatisfy { row in
            row.keys.allSatisfy { $0.action.type != .code && $0.action.type != .literal }
        }
    }

    /// The main shell whose rows still have the preset's key counts and widths, so the 26-key
    /// letters sit in the standard equal columns with the familiar stagger. Edited widths or
    /// counts are drawn at their declared weights instead, still between Shift and Delete.
    static func matchesMainShellColumns(_ definition: LayoutDefinition, as layout: LayoutInput.Builtin) -> Bool {
        matchesMainShell(definition, as: layout)
            && mainRowsMatch(definition, preset(for: layout), comparingActions: false)
    }

    /// Whether the keyboard draws its own bottom row for this layout. The presets' fourth row is
    /// a stand-in for that row, not a design: while it is unedited the keyboard's control row
    /// replaces it whatever the main keys say. An edited fourth row is the author's and is drawn
    /// as declared.
    static func matchesControlRowPolicy(_ definition: LayoutDefinition, as layout: LayoutInput.Builtin) -> Bool {
        definition.rows.count == PhoneKeypadMetrics.mainRowCount + 1
            && matchesMainShell(definition, as: layout)
            && definition.rows.last == preset(for: layout).rows.last
    }

    /// The main area is the first three rows by declaration, not by inferring a control row: the
    /// key count, width and (unless told otherwise) primary action of each main key must still be
    /// the preset's.
    private static func mainRowsMatch(
        _ definition: LayoutDefinition, _ preset: LayoutDefinition, comparingActions: Bool = true
    ) -> Bool {
        let count = PhoneKeypadMetrics.mainRowCount
        guard definition.rows.count >= count else { return false }
        return zip(definition.rows.prefix(count), preset.rows.prefix(count)).allSatisfy { row, presetRow in
            row.keys.count == presetRow.keys.count
                && zip(row.keys, presetRow.keys).allSatisfy {
                    $0.width == $1.width && (!comparingActions || $0.action == $1.action)
                }
        }
    }
}
