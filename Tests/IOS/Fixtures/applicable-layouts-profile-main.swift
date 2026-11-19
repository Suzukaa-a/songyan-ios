import Foundation
import KeyboardCore
import LayoutKit

// The layouts 我的键盘 offers by what the scheme's speller needs, compiled from the Host's source section.

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

let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
let all = KeyboardLayoutKind.allCases
let registry = try LayoutRegistry()

func offered(
    _ id: String, _ profile: SchemaKeyProfile?, in registry: LayoutRegistry = registry
) -> [HostLayoutAvailability.ApplicableLayout] {
    HostLayoutAvailability.applicableLayouts(
        schemaID: id, shapes: all, descriptors: [KeyboardSchemaDescriptor(id: id, name: id, profile: profile)],
        in: registry)
}

func names(_ list: [HostLayoutAvailability.ApplicableLayout]) -> [String] {
    list.map { $0.shape.rawValue + "#" + $0.layoutID }
}

// A shape code scheme gets only 26-key layouts, the code board first.
let wubi = SchemaKeyProfile(kind: .shapeCode, codes: letters + [";", "'"])
let wubiList = offered("wubi86", wubi)
checkEqual(
    names(wubiList), ["qwerty26#auto.wubi86.keys26", "qwerty26#qwerty26"],
    "a shape code scheme is offered the code board first and plain 26 keys")
checkEqual(wubiList[0].generated, .keys26, "the code board is a generated layout")
checkEqual(wubiList[0].missingCodes, [], "the code board lacks nothing")
checkEqual(wubiList[1].missingCodes, [";", "'"], "plain 26 keys lack what wubi needs")

// A stroke scheme gets the pad, then plain and code boards.
let strokes = zip(["h", "s", "p", "n", "z"], ["⼀", "⼁", "⼃", "⼂", "⼄"]).map {
    SchemaKeyProfile.Stroke(code: $0, label: $1)
}
let stroke = SchemaKeyProfile(
    kind: .strokes, codes: strokes.map(\.code) + ["'", "`"], strokes: strokes, optionalCodes: ["'", "`"])
let strokeList = offered("stroke", stroke)
checkEqual(
    names(strokeList),
    ["qwerty26#auto.stroke.strokes", "qwerty26#qwerty26", "qwerty26#auto.stroke.keys26"],
    "a stroke scheme is offered the pad, plain 26 keys, then the code board")
checkEqual(strokeList[0].generated, .strokes, "the pad is a generated layout")
checkEqual(strokeList[1].missingCodes, [], "plain 26 keys only lack keys the scheme can go without: no warning")

// A syllabic scheme keeps every shape; the code board is only an extra.
let ice = SchemaKeyProfile(kind: .syllabic, codes: letters + ["`", "'"])
let iceList = offered("rime_ice", ice)
checkEqual(
    Set(names(iceList)),
    ["qwerty26#qwerty26", "merged14#merged14", "merged18#merged18", "phone9#phone9", "qwerty26#auto.rime_ice.keys26"],
    "a syllabic scheme keeps its four shapes and gets the code board as an extra")
checkEqual(names(iceList).first, "qwerty26#qwerty26", "plain 26 keys stays the default")
checkEqual(
    offered("pinyin", SchemaKeyProfile(kind: .syllabic, codes: letters)).count, 4,
    "nothing is added when 26 keys suffice")

// An auxiliary key the spelling never uses (rime-ice's backtick) is optional: plain 26 keys stays
// offered and first; a symbol the spelling does use (Microsoft Shuangpin's ";") hides it.
let iceOptional = SchemaKeyProfile(kind: .syllabic, codes: letters + ["`", "'"], optionalCodes: ["`", "'"])
checkEqual(
    names(offered("rime_ice", iceOptional)).filter { $0.hasPrefix("qwerty26#") },
    ["qwerty26#qwerty26", "qwerty26#auto.rime_ice.keys26"],
    "an unused auxiliary key keeps plain 26 keys offered, first, then the extra board")
checkEqual(
    offered("rime_ice", iceOptional).first { $0.layoutID == "qwerty26" }?.missingCodes, [],
    "plain 26 keys carry no warning for rime-ice's optional keys")
let microsoft = SchemaKeyProfile(kind: .syllabic, codes: letters + [";", "'"], optionalCodes: ["'"])
checkEqual(
    names(offered("microsoft", microsoft)).filter { $0.hasPrefix("qwerty26#") },
    ["qwerty26#auto.microsoft.keys26"],
    "a symbol the spelling uses hides plain 26 keys")

// Unknown: plain 26 keys only. No profile: as before.
checkEqual(
    names(offered("lua_only", SchemaKeyProfile(kind: .unknown))), ["qwerty26#qwerty26"],
    "an unknown profile gets plain 26 keys")
checkEqual(offered("old", nil).count, 4, "a scheme without a profile is offered as before")
check(offered("old", nil).allSatisfy { $0.generated == nil }, "a scheme without a profile gets no generated layout")

// A 26-key layout with no key for a code the speller needs is not offered; one that lacks only the
// delimiter still is, with the missing-codes line. A profile that does not tell the two apart never filters.
let zhuyinCodes = "1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/-".map(String.init)
let zhuyin = SchemaKeyProfile(kind: .syllabic, codes: zhuyinCodes + ["'"], optionalCodes: ["'"])
check(
    !names(offered("my_zhuyin", zhuyin)).contains("qwerty26#qwerty26"),
    "plain 26 keys cannot type a zhuyin alphabet and is not offered")
check(
    names(offered("my_zhuyin", SchemaKeyProfile(kind: .syllabic, codes: zhuyinCodes + ["'"])))
        .contains("qwerty26#qwerty26"),
    "a profile that does not tell optional codes apart never filters")
check(
    names(offered("bopomofo", zhuyin)).contains("qwerty26#zhuyin41"),
    "the 41-key zhuyin board is offered")
var zhuyinCopy = registry
try zhuyinCopy.install(
    LayoutDefinition(
        id: "copy26", name: "26 键 副本", input: BuiltinLayouts.qwerty26.input, rows: BuiltinLayouts.qwerty26.rows
    ).encoded())
check(
    !offered("bopomofo", zhuyin, in: zhuyinCopy).contains { $0.layoutID == "copy26" },
    "a copy of plain 26 keys is not offered for zhuyin either")
let pinyinNoDelimiter = offered(
    "pinyin", SchemaKeyProfile(kind: .syllabic, codes: letters + ["'"], optionalCodes: ["'"]))
checkEqual(
    pinyinNoDelimiter.first { $0.layoutID == "qwerty26" }?.missingCodes, [],
    "missing only an optional code keeps the layout offered, with nothing to warn about")

// A layout the user copied is listed with its own missing codes.
var withCopy = registry
let copy = LayoutDefinition(
    id: "mine", name: "副本", input: BuiltinLayouts.qwerty26.input, rows: BuiltinLayouts.qwerty26.rows)
try withCopy.install(copy.encoded())
let mine = offered("wubi86", SchemaKeyProfile(kind: .shapeCode, codes: letters + [";"]), in: withCopy)
    .first { $0.layoutID == "mine" }
checkEqual(mine?.missingCodes, [";"], "a copied layout shows what it lacks")

// An installed generated layout is not listed twice.
var installed = registry
try installed.install(
    GeneratedLayouts.keys26(schemaID: "wubi86", name: "26+", codes: wubi.codes).encoded())
let again = offered("wubi86", wubi, in: installed)
checkEqual(
    names(again), ["qwerty26#auto.wubi86.keys26", "qwerty26#qwerty26"], "an installed generated layout is listed once")
checkEqual(again[0].generated, .keys26, "and stays a generated layout")

// The layout a generated keyboard opens on is made from the profile.
let definition = HostLayoutAvailability.generatedDefinition(
    layoutID: "auto.wubi86.keys26", schemaID: "wubi86",
    descriptors: [KeyboardSchemaDescriptor(id: "wubi86", name: "", profile: wubi)])
checkEqual(definition?.id, "auto.wubi86.keys26", "the generated layout is built from the profile")
check(
    HostLayoutAvailability.generatedDefinition(layoutID: "qwerty26", schemaID: "wubi86", descriptors: []) == nil,
    "an ordinary layout has no generated definition")

// The install picker ticks the first layout of each input method and titles generated layouts before they exist.
let descriptors = [KeyboardSchemaDescriptor(id: "wubi86", name: "", profile: wubi)]
let generatedKeyboard = PublishedKeyboard(schemaID: "wubi86", layout: .qwerty26, board: "auto.wubi86.keys26")
checkEqual(
    wubiList.first.map { PublishedKeyboard(schemaID: "wubi86", layout: $0.shape, board: $0.layoutID) },
    generatedKeyboard, "the picker's default for a shape code scheme is its code board")
checkEqual(
    HostLayoutAvailability.choiceTitle(generatedKeyboard, descriptors: descriptors, in: registry),
    UserTerminology.keys26Name(adding: LayoutCodeCoverage.missing(BuiltinLayouts.qwerty26, needed: wubi.codes)),
    "a generated layout not in the catalog yet is titled as it will be stored")
check(
    UserTerminology.keys26Name(adding: [";", "'"]).contains("; '"),
    "the generated board's name lists the keys it adds")
checkEqual(
    HostLayoutAvailability.choiceTitle(
        PublishedKeyboard(schemaID: "wubi86", layout: .qwerty26, board: "mine"), descriptors: descriptors, in: withCopy),
    "副本", "a copied layout is titled by its saved name")

if failures > 0 { fatalError("\(failures) applicable layout checks failed") }
print("applicable layout checks passed")
