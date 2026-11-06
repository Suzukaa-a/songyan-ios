import Foundation
import KeyboardCore
import LayoutKit

// The Host's pairing resolver, compiled from its source section, against the real layout registry.

var failures = 0

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    if value() {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: " + label)
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    check(actual == expected, label + " (got \(actual), expected \(expected))")
}

let schemes = [
    KeyboardSchemaDescriptor(id: "bopomofo_tw", name: "注音"),
    KeyboardSchemaDescriptor(id: "cangjie5", name: "仓颉五代"),
    KeyboardSchemaDescriptor(id: "quick5", name: "速成"),
    KeyboardSchemaDescriptor(id: "jyut6ping3", name: "粤拼"),
    KeyboardSchemaDescriptor(id: "songyan_quanpin", name: "全拼"),
    KeyboardSchemaDescriptor(id: "kagiroi", name: "日本語"),
]
// The declared bopomofo alphabet identifies the family without the id.
let alphabets = [
    KeyboardSchemaDescriptor(
        id: "custom_board", name: "自定义", alphabet: "1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik9ol0p-;,./")
]

func effective(
    _ schemaID: String, layout: KeyboardLayoutKind = .qwerty26,
    descriptors: [KeyboardSchemaDescriptor], in registry: LayoutRegistry
) -> String {
    HostLayoutAvailability.effectiveMainLayoutID(
        schemaID: schemaID, layout: layout, descriptors: descriptors, in: registry)
}

var registry = try LayoutRegistry()

// A newly added keyboard has no saved pairing: its scheme family supplies the board.
checkEqual(
    effective("bopomofo_tw", descriptors: schemes, in: registry), "zhuyin41",
    "a new zhuyin keyboard defaults to the 41-key board")
checkEqual(
    effective("cangjie5", descriptors: schemes, in: registry), "cangjie26",
    "a new Cangjie keyboard defaults to the 26-key board")
checkEqual(
    effective("quick5", descriptors: schemes, in: registry), "cangjie26",
    "a new Quick keyboard defaults to the 26-key board")
checkEqual(
    effective("jyut6ping3", descriptors: schemes, in: registry), "qwerty26",
    "Cantonese keeps the 26-key board")
checkEqual(
    effective("kagiroi", descriptors: schemes, in: registry), "romaji26",
    "a new Japanese keyboard defaults to the romaji board")
checkEqual(
    effective("songyan_quanpin", descriptors: schemes, in: registry), "qwerty26",
    "the bundled pinyin keeps today's default")
checkEqual(
    effective("unknown_scheme", descriptors: schemes, in: registry), "qwerty26",
    "an unknown scheme keeps today's default")
checkEqual(
    effective("custom_board", descriptors: alphabets, in: registry), "zhuyin41",
    "a declared bopomofo alphabet picks the 41-key board")
checkEqual(
    effective("bopomofo_tw", layout: .phone9, descriptors: schemes, in: registry), "phone9",
    "a stale folded shape this family may not use falls back inside its own shape")

// A saved pairing is what the keyboard really uses, and it is never rewritten.
let key = KeyboardCompositionKey(inputMethodID: "bopomofo_tw", layout: .qwerty26)
try registry.setComposition(KeyboardComposition(mainLayoutID: "qwerty26"), for: key.rawValue)
checkEqual(
    effective("bopomofo_tw", descriptors: schemes, in: registry), "qwerty26",
    "a saved pairing is kept")
try registry.setComposition(KeyboardComposition(mainLayoutID: "cangjie26"), for: key.rawValue)
checkEqual(
    effective("bopomofo_tw", descriptors: schemes, in: registry), "zhuyin41",
    "a saved pairing this family may not use falls back to its own board")
checkEqual(
    registry.composition(for: key).mainLayoutID, "cangjie26",
    "the fallback never rewrites the saved pairing")

// The shape gate stays: only the 26-key shape is offered to the traditional families.
check(
    HostLayoutAvailability.allows(kind: .qwerty26, schemaID: "bopomofo_tw", descriptors: schemes),
    "zhuyin may use the 26-key shape")
check(
    !HostLayoutAvailability.allows(kind: .merged14, schemaID: "bopomofo_tw", descriptors: schemes),
    "zhuyin may not use the 14-key shape")
check(
    HostLayoutAvailability.allows(kind: .phone9, schemaID: "songyan_quanpin", descriptors: schemes),
    "the bundled pinyin keeps the 9-key shape")

// The Host row names the board the pairing resolved, so a 41-key board is not read as its
// transport shape ("26 键"); the input method follows. Every other board keeps the published title.
let compiledCatalog = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard let catalog = Bundle(path: compiledCatalog.path) else {
    fatalError("FAIL: compiled catalog bundle unreadable")
}

func builtinBoardName(_ schemaID: String) -> (id: String, name: String?) {
    let id = effective(schemaID, descriptors: schemes, in: registry)
    return (
        id,
        registry.resolvedLayout(id: id).flatMap {
            UserTerminology.builtinLayoutName(physicalLayoutID: $0.id, in: catalog)
        }
    )
}

let zhuyinBoard = builtinBoardName("bopomofo_tw")
checkEqual(zhuyinBoard.id, "zhuyin41", "the zhuyin keyboard resolves the 41-key board")
check(zhuyinBoard.name != nil, "the resolved 41-key board has a localized name")
let zhuyinKeyboard = UserKeyboard(
    inputMethodID: "bopomofo_tw", inputMethodName: "注音（台湾）", layout: .qwerty26)
let zhuyinTitle = zhuyinKeyboard.title(physicalLayoutName: zhuyinBoard.name)
checkEqual(
    zhuyinTitle, "注音（台湾） · \(zhuyinBoard.name ?? "")",
    "the zhuyin row keeps the input method before its real board name")
check(!zhuyinTitle.contains("26 键"), "the zhuyin row never reads as the 26-key shape")
check(zhuyinTitle.hasSuffix(zhuyinBoard.name ?? "\u{0}"), "the physical board name follows the input method")

let cangjieBoard = builtinBoardName("cangjie5")
checkEqual(cangjieBoard.id, "cangjie26", "the Cangjie keyboard resolves the 26-key board")
check(cangjieBoard.name != nil, "the resolved Cangjie board has a localized name")
checkEqual(
    UserKeyboard(inputMethodID: "cangjie5", inputMethodName: "仓颉五代", layout: .qwerty26)
        .title(physicalLayoutName: cangjieBoard.name),
    "仓颉五代 · \(cangjieBoard.name ?? "")",
    "the Cangjie row keeps the input method before its real board name")

let pinyinBoard = builtinBoardName("songyan_quanpin")
checkEqual(pinyinBoard.id, "qwerty26", "the bundled pinyin keeps the 26-key board")
check(pinyinBoard.name == nil, "a shape preset is not renamed")
checkEqual(
    UserKeyboard(inputMethodID: "songyan_quanpin", inputMethodName: "全拼", layout: .qwerty26)
        .title(physicalLayoutName: pinyinBoard.name),
    "全拼 · 26 键",
    "every other keyboard keeps the published title")

if failures > 0 { fatalError("\(failures) host pairing checks failed") }
print("host pairing checks passed")
