import Foundation

/// A publication record written before keyboards named their layout reads as the same keyboards
/// and selection, and a keyboard on a user's layout is saved and selected like any other.
func layoutKeyboardsChecks(_ base: URL) throws {
    let fm = FileManager.default
    func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    let root = base.appendingPathComponent("store")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let before = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("pre-layout-keyboards/active.json")
    try fm.copyItem(at: before, to: root.appendingPathComponent("active.json"))
    guard let activation = try KeyboardRecipeStore.activation(rootURL: root) else {
        fatalError("the older record must decode")
    }
    check(
        activation.keyboards.map(\.id) == ["kagiroi:qwerty26", "kagiroi:qwerty26#kana12"],
        "the roster in use keeps both Japanese keyboards")
    check(
        activation.selectedKeyboard == PublishedKeyboard(schemaID: "kagiroi", layout: .qwerty26),
        "the keyboard in use is the one saved without a layout")
    check(activation.selectedBoard == nil, "its layout still comes from the pairing")
    check(
        activation.keyboardsBySource?["userScheme:songyan-builtin"]?.map(\.id)
            == [
                "songyan_quanpin:qwerty26", "songyan_quanpin:phone9", "songyan_flypy:qwerty26",
                "songyan_flypy:merged14",
            ], "the other input scheme keeps its keyboards")
    check(activation.hasKeyboard(namingLayout: "kana12"), "a keyboard names the kana board")
    check(!activation.hasKeyboard(namingLayout: "romaji26"), "no keyboard names the romaji board")
    check(!activation.hasKeyboard(namingLayout: "qwerty26"), "an older keyboard names no layout")
    // Encoding the record again keeps every older keyboard without a layout.
    let again = try JSONDecoder().decode(
        KeyboardRecipeStore.Activation.self, from: JSONEncoder().encode(activation))
    check(again.keyboards == activation.keyboards, "the roster survives a rewrite")
    check(again.keyboardsBySource == activation.keyboardsBySource, "so do the other rosters")

    // A keyboard on a user's layout: published, selected and matched by the running route.
    let resources = base.appendingPathComponent("resources")
    let build = base.appendingPathComponent("build")
    for directory in [resources, build] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    try Data("schema_list:\n  - schema: rime_ice\n".utf8).write(to: build.appendingPathComponent("default.yaml"))
    try Data("schema: fixture".utf8).write(to: build.appendingPathComponent("rime_ice.schema.yaml"))
    let fresh = base.appendingPathComponent("fresh")
    try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
    let plain = PublishedKeyboard(schemaID: "rime_ice", layout: .qwerty26, board: "qwerty26")
    let mine = PublishedKeyboard(schemaID: "rime_ice", layout: .qwerty26, board: "my-layout")
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "fixture", rootURL: fresh,
        kind: .userScheme, packageID: "pkg-a", selectedSchemaID: "rime_ice", layout: .qwerty26,
        board: "my-layout", publishedKeyboards: [plain, mine])
    guard let published = try KeyboardRecipeStore.activation(rootURL: fresh) else {
        fatalError("the publication must be readable")
    }
    check(published.keyboards == [plain, mine], "both keyboards of one shape are published")
    check(published.selectedKeyboard == mine, "the keyboard on the user's layout is in use")
    check(published.hasKeyboard(namingLayout: "my-layout"), "its layout counts as used")
    try KeyboardRecipeStore.saveSelection(
        schemaID: "rime_ice", layout: .qwerty26, board: "qwerty26", runtimeIdentity: .published, rootURL: fresh)
    check(
        try KeyboardRecipeStore.activation(rootURL: fresh)?.selectedKeyboard == plain,
        "switching to the shipped layout of the same shape is saved")
}
