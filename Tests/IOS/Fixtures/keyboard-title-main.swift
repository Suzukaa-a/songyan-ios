import Darwin
import Foundation
import KeyboardCore

// Production keyboard-title rule, compiled from its source section, against the real published
// roster projection (the title is the resolved scheme name plus the transport shape, never an
// author-written name).

var failures = 0

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    if value() {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: " + label)
    }
    // A failed check ends in fatalError: flush first so the evidence survives the abort.
    fflush(stdout)
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    check(actual == expected, label + " (got \(actual), expected \(expected))")
}

let compiledCatalog = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard let catalog = Bundle(path: compiledCatalog.path) else {
    fatalError("FAIL: compiled catalog bundle unreadable")
}

func builtinName(_ id: String) -> String? {
    UserTerminology.builtinLayoutName(physicalLayoutID: id, in: catalog)
}

/// The published projection the roster really returns for a combination.
func roster(_ schemaID: String, _ layout: KeyboardLayoutKind, name: String) -> [UserKeyboard] {
    [UserKeyboard(inputMethodID: schemaID, inputMethodName: name, layout: layout)]
}

func publishedTitle(_ schemaID: String, _ layout: KeyboardLayoutKind, name: String) -> String? {
    UserKeyboardRoster.currentTitle(
        schemaID: schemaID, layout: layout, in: roster(schemaID, layout, name: name))
}

/// The matched input method's own name, as the panel now passes it to the rule.
func rosterName(_ schemaID: String, _ layout: KeyboardLayoutKind, name: String) -> String? {
    UserKeyboardRoster.currentInputMethodName(
        schemaID: schemaID, layout: layout, in: roster(schemaID, layout, name: name))
}

func title(
    _ published: String?, scheme: String?, isBundled: Bool, physicalLayoutID: String?,
    definitionName: String? = nil, kindName: String = UserTerminology.layoutName(.qwerty26)
) -> String {
    KeyboardTitleRule.title(
        published: published, inputMethodName: scheme, isBundled: isBundled,
        physicalLayoutID: physicalLayoutID, definitionName: definitionName, kindName: kindName,
        builtinName: builtinName)
}

// Both bundled traditional boards show their own localized name, never the 26-key shape name.
for (id, schema, scheme) in [
    ("zhuyin41", "bopomofo_tw", "注音（台湾）"),
    ("cangjie26", "cangjie5", "仓颉五代"),
] {
    guard let name = builtinName(id) else { fatalError("FAIL: no localized name for " + id) }
    print("NAME \(id) \(name)")
    // The text snapshot resolves the real board; the published title only carries the transport
    // shape, so taking it verbatim would hide the 41/26-key board.
    let published = publishedTitle(schema, .qwerty26, name: scheme)
    checkEqual(
        title(
            published, scheme: rosterName(schema, .qwerty26, name: scheme), isBundled: true,
            physicalLayoutID: id),
        "\(scheme) · \(name)",
        "\(id) keeps the input method before the real board name")
}

// Without a published keyboard the shipped board still names itself.
checkEqual(
    title(nil, scheme: nil, isBundled: true, physicalLayoutID: "zhuyin41"),
    builtinName("zhuyin41"),
    "a shipped board names itself when nothing is published")
// An input method without a real name shows the board alone, never a dangling separator.
checkEqual(
    title(
        publishedTitle("bopomofo_tw", .qwerty26, name: ""),
        scheme: rosterName("bopomofo_tw", .qwerty26, name: ""), isBundled: true,
        physicalLayoutID: "zhuyin41"),
    builtinName("zhuyin41"),
    "an unnamed input method shows the board alone")

// Every other shape, id and user layout keeps today's order and wording.
checkEqual(
    title(
        publishedTitle("songyan_quanpin", .qwerty26, name: "全拼"),
        scheme: rosterName("songyan_quanpin", .qwerty26, name: "全拼"), isBundled: true,
        physicalLayoutID: "qwerty26"),
    "全拼 · 26 键",
    "the bundled 26-key board keeps today's name")
checkEqual(
    title(nil, scheme: nil, isBundled: true, physicalLayoutID: "qwerty26"),
    "26 键",
    "the bundled 26-key board keeps today's fallback")
checkEqual(
    title(nil, scheme: nil, isBundled: true, physicalLayoutID: "mine", definitionName: "ignored"),
    "26 键",
    "an unknown bundled-content id falls back to the shape name")
checkEqual(
    title(nil, scheme: nil, isBundled: false, physicalLayoutID: "copy-id", definitionName: "我的布局"),
    "我的布局",
    "a user layout keeps its own author name")
checkEqual(
    title(nil, scheme: nil, isBundled: false, physicalLayoutID: "copy-id"),
    "26 键",
    "a nameless user layout keeps the shape name")
checkEqual(
    title("我的布局", scheme: nil, isBundled: false, physicalLayoutID: "copy-id"),
    "我的布局",
    "a user layout's own name still wins")
// A user layout that carries a builtin id is not renamed: only the shipped board is.
checkEqual(
    title(nil, scheme: nil, isBundled: false, physicalLayoutID: "zhuyin41", definitionName: "我的注音"),
    "我的注音",
    "a user layout is never given a shipped board name")

// Ids this build does not ship are never renamed.
for id in ["qwerty26", "merged14", "merged18", "phone9", "mine", ""] {
    check(builtinName(id) == nil, "unknown layout id is not renamed: \(id)")
}
check(UserTerminology.layoutName(.qwerty26) == "26 键", "the 26-key shape name is unchanged")
check(builtinName("zhuyin41") != nil && builtinName("cangjie26") != nil, "both shipped board names resolve")

if failures > 0 { fatalError("\(failures) keyboard title checks failed") }
print("keyboard title checks passed")
