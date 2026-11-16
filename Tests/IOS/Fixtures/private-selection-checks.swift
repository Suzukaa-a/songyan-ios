import Foundation

/// A keyboard picked without Full Access is kept in the extension's own defaults and applies until
/// the host app picks a keyboard itself.
func privateSelectionChecks(_ base: URL) throws {
    let fm = FileManager.default
    let root = base.appendingPathComponent("store")
    let resources = base.appendingPathComponent("resources")
    let build = base.appendingPathComponent("build")
    for directory in [root, resources, build] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    for schema in ["rime_ice", "double_pinyin_flypy"] {
        try Data("schema: fixture".utf8).write(to: build.appendingPathComponent("\(schema).schema.yaml"))
    }
    try Data("schema_list:\n  - schema: rime_ice\n  - schema: double_pinyin_flypy\n".utf8)
        .write(to: build.appendingPathComponent("default.yaml"))
    // The host app has added two keyboards; the keyboard menu offers exactly these.
    let keyboards = [
        PublishedKeyboard(schemaID: "rime_ice", layout: .qwerty26),
        PublishedKeyboard(schemaID: "double_pinyin_flypy", layout: .qwerty26),
    ]
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "fixture", rootURL: root,
        kind: .userScheme, packageID: "pkg-a", selectedSchemaID: "rime_ice", layout: .qwerty26,
        publishedKeyboards: keyboards)
    let defaults = UserDefaults(suiteName: "private-selection-\(UUID().uuidString)")!
    func selected() -> (String?, KeyboardLayoutKind?) {
        let read = KeyboardRecipeStore.applyingPrivateSelection(
            KeyboardRecipeStore.readSelection(rootURL: root), defaults: defaults)
        let activation = try! JSONDecoder().decode(KeyboardRecipeStore.Activation.self, from: read.data!)
        return (activation.selectedSchemaID, activation.selectedLayout)
    }
    let hostChoice = selected()
    check(hostChoice.0 == "rime_ice", "without a kept pick the host's choice applies")

    // A pick made in the keyboard without Full Access applies on the next read.
    check(
        KeyboardRecipeStore.savePrivateSelection(
            schemaID: "double_pinyin_flypy", layout: .qwerty26, board: nil, defaults: defaults, rootURL: root),
        "a published record is there to base the pick on")
    let kept = selected()
    check(kept.0 == "double_pinyin_flypy" && kept.1 == .qwerty26, "the kept pick applies: \(kept)")
    check(selected() == kept, "it keeps applying while nothing changed")

    // The shared file itself never changes: other processes still read the host's choice.
    let shared = try JSONDecoder().decode(
        KeyboardRecipeStore.Activation.self, from: Data(contentsOf: root.appendingPathComponent("active.json")))
    check(shared.selectedSchemaID == "rime_ice", "the shared record is untouched")

    // A pick of a keyboard the host app has not added is dropped.
    KeyboardRecipeStore.savePrivateSelection(
        schemaID: "double_pinyin_flypy", layout: .merged14, board: nil, defaults: defaults, rootURL: root)
    check(selected().0 == "rime_ice", "an unpublished pick does not apply")
    check(defaults.data(forKey: KeyboardRecipeStore.privateSelectionKey) == nil, "and is forgotten")

    // The host app choosing a keyboard afterwards wins, and the kept pick is forgotten.
    KeyboardRecipeStore.savePrivateSelection(
        schemaID: "double_pinyin_flypy", layout: .qwerty26, board: nil, defaults: defaults, rootURL: root)
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "host", rootURL: root,
        kind: .userScheme, packageID: "pkg-a", selectedSchemaID: "rime_ice", layout: .qwerty26,
        publishedKeyboards: keyboards)
    check(selected().0 == "rime_ice", "a later host choice wins")
    check(defaults.data(forKey: KeyboardRecipeStore.privateSelectionKey) == nil, "the stale pick is forgotten")

    // Clearing forgets the pick outright (the shared record took the choice).
    KeyboardRecipeStore.savePrivateSelection(
        schemaID: "double_pinyin_flypy", layout: .qwerty26, board: nil, defaults: defaults, rootURL: root)
    KeyboardRecipeStore.clearPrivateSelection(defaults: defaults)
    check(selected().0 == "rime_ice", "a cleared pick no longer applies")
    print("private selection checks passed")
}
