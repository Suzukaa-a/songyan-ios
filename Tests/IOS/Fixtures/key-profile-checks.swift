import Foundation

/// What the deployment learned about each scheme's speller reaches the descriptors the keyboard
/// and the host read; a build from before profiles reads as no profile at all.
func keyProfileChecks(_ base: URL) throws {
    let fm = FileManager.default
    func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    let build = base.appendingPathComponent("build")
    try fm.createDirectory(at: build, withIntermediateDirectories: true)
    try "schema_list:\n  - schema: wubi86\n  - schema: stroke\n".write(
        to: build.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
    for id in ["wubi86", "stroke"] {
        try "schema:\n  name: \(id)\nspeller:\n  alphabet: abcdefghijklmnopqrstuvwxyz\n".write(
            to: build.appendingPathComponent("\(id).schema.yaml"), atomically: true, encoding: .utf8)
    }

    let before = try KeyboardRecipeStore.deployedSchemas(build: build)
    check(before.map(\.id) == ["wubi86", "stroke"], "both schemes are listed")
    check(before.allSatisfy { $0.profile == nil }, "a build from before profiles has no profile")

    let profiles = [
        "wubi86": SchemaKeyProfile(kind: .shapeCode, codes: ["a", ";"]),
        "stroke": SchemaKeyProfile(
            kind: .strokes, codes: ["h"], strokes: [.init(code: "h", label: "⼀")]),
    ]
    try SchemaKeyProfile.encode(profiles).write(to: build.appendingPathComponent(SchemaKeyProfile.fileName))
    let after = try KeyboardRecipeStore.deployedSchemas(build: build)
    check(after.map(\.profile) == [profiles["wubi86"], profiles["stroke"]], "each scheme carries its own profile")
    check(after.first?.alphabet == "abcdefghijklmnopqrstuvwxyz", "the rest of the descriptor is unchanged")
    let again = try JSONDecoder().decode([KeyboardSchemaDescriptor].self, from: JSONEncoder().encode(after))
    check(again == after, "the descriptors keep their profiles through the saved list")
    print("key profile checks passed")
}
