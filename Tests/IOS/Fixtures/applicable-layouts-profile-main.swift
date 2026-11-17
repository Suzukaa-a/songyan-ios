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
let stroke = SchemaKeyProfile(kind: .strokes, codes: strokes.map(\.code) + ["'", "`"], strokes: strokes)
let strokeList = offered("stroke", stroke)
checkEqual(
    names(strokeList),
    ["qwerty26#auto.stroke.strokes", "qwerty26#qwerty26", "qwerty26#auto.stroke.keys26"],
    "a stroke scheme is offered the pad, plain 26 keys, then the code board")
checkEqual(strokeList[0].generated, .strokes, "the pad is a generated layout")
check(strokeList[1].missingCodes.contains("`"), "plain 26 keys lack the backtick a stroke scheme needs")

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

// Unknown: plain 26 keys only. No profile: as before.
checkEqual(
    names(offered("lua_only", SchemaKeyProfile(kind: .unknown))), ["qwerty26#qwerty26"],
    "an unknown profile gets plain 26 keys")
checkEqual(offered("old", nil).count, 4, "a scheme without a profile is offered as before")
check(offered("old", nil).allSatisfy { $0.generated == nil }, "a scheme without a profile gets no generated layout")

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

if failures > 0 { fatalError("\(failures) applicable layout checks failed") }
print("applicable layout checks passed")
