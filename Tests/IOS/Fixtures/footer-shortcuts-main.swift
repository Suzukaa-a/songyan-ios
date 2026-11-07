import Foundation
import LayoutKit

// Production footer-shortcut plan, compiled from its source section.

var failures = 0

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    if value() {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: " + label)
    }
}

// The two bundled traditional boards declare every control key themselves, so the bar must not
// add its own 123 / symbol / globe / 中英 entries: both platforms draw the same footer.
for board in [BuiltinLayouts.zhuyin41, BuiltinLayouts.cangjie26] {
    let supplement = KeyboardFooterShortcutPlan.supplements(physicalLayoutID: board.id)
    let plan = KeyboardFooterShortcutPlan(
        controlRow: board.rows.last, supplementShortcuts: supplement)
    check(!supplement, "\(board.id) draws its whole footer itself")
    check(!plan.addsNumericShortcut, "\(board.id) keeps its declared 123 key")
    check(!plan.addsSymbolShortcut, "\(board.id) adds no symbol shortcut")
    check(!plan.addsLayoutSwitch, "\(board.id) keeps its declared 中/英 key")
    check(
        !plan.addsGlobe(definitionHasGlobe: true, showsGlobe: true),
        "\(board.id) keeps its declared globe key")
    check(
        !plan.addsGlobe(definitionHasGlobe: false, showsGlobe: true),
        "\(board.id) never gets an extra globe even when the row's globe is hidden")
}

check(
    BuiltinLayouts.zhuyin41.rows.last?.keys.count == 6,
    "the 41-key board declares 6 control keys")
check(
    BuiltinLayouts.cangjie26.rows.last?.keys.count == 5,
    "the 26-key board declares 5 control keys (its shell draws Delete)")

// A generic authored row that declares its own 中英 key with .languageSwitch: the bar must not
// add a second one, and its other shortcuts stay exactly as before.
let legacyAuthored = LayoutRow(keys: [
    LayoutKey(label: "🌐", action: LayoutAction(.globe)),
    LayoutKey(label: "123", action: LayoutAction.pageSwitch(.numeric)),
    LayoutKey(label: "中/英", action: LayoutAction.languageSwitch()),
    LayoutKey(label: "空格", width: 4, action: LayoutAction(.space)),
    LayoutKey(label: "⏎", action: LayoutAction(.enter)),
])
let legacy = KeyboardFooterShortcutPlan(controlRow: legacyAuthored)
check(legacy.supplementShortcuts, "an authored row keeps the bar's shortcut supplement")
check(!legacy.addsLayoutSwitch, "a declared languageSwitch key is not duplicated")
check(!legacy.addsNumericShortcut, "a declared 123 key is not duplicated")
check(legacy.addsSymbolShortcut, "the symbol shortcut is still added when undeclared")
check(
    !legacy.addsGlobe(definitionHasGlobe: true, showsGlobe: true),
    "a declared globe key is not duplicated")

// The legacy .modeSwitch declaration is still recognized.
let modeOnly = KeyboardFooterShortcutPlan(
    controlRow: LayoutRow(keys: [
        LayoutKey(label: "布局", action: LayoutAction(.modeSwitch, value: "nextLayout"))
    ]))
check(!modeOnly.addsLayoutSwitch, "a declared modeSwitch key is still recognized")

// The bundled 26-key default keeps today's behaviour exactly.
let qwerty = KeyboardFooterShortcutPlan(controlRow: BuiltinLayouts.qwerty26.rows.last)
check(
    qwerty.addsNumericShortcut && qwerty.addsSymbolShortcut,
    "the 26-key default still gets the undeclared 123 and symbol shortcuts")
check(!qwerty.addsLayoutSwitch, "the 26-key default's declared layout key is not duplicated")
check(
    !qwerty.addsGlobe(definitionHasGlobe: true, showsGlobe: true),
    "the 26-key default's declared globe is not duplicated")

// Only the two bundled boards stop the supplement; every other layout keeps today's behaviour.
check(KeyboardFooterShortcutPlan.supplements(physicalLayoutID: nil), "a schema-only row keeps it")
check(
    KeyboardFooterShortcutPlan.supplements(physicalLayoutID: "qwerty26"),
    "the bundled 26-key default keeps it")
check(
    KeyboardFooterShortcutPlan.supplements(physicalLayoutID: "mine"),
    "an unknown user layout keeps it")

// A bar without a declared control row still gets every shortcut, as today.
let bare = KeyboardFooterShortcutPlan(controlRow: nil)
check(
    bare.addsNumericShortcut && bare.addsSymbolShortcut && bare.addsLayoutSwitch,
    "a row-less bar still gets 123, symbol and layout shortcuts")
check(
    bare.addsGlobe(definitionHasGlobe: false, showsGlobe: true)
        && !bare.addsGlobe(definitionHasGlobe: true, showsGlobe: true)
        && !bare.addsGlobe(definitionHasGlobe: false, showsGlobe: false),
    "the row-less globe follows definitionHasGlobe and showsGlobe")

if failures > 0 { fatalError("\(failures) footer shortcut checks failed") }
print("footer shortcut checks passed")
