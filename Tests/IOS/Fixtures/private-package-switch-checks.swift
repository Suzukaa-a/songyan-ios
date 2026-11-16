import Foundation

/// A switch to another kept package made without Full Access is remembered by the keyboard as a
/// pointer to the generation the host app already keeps (no copy), applies until the host app
/// changes the shared record, and is written into the shared record once Full Access is on.
func privatePackageSwitchChecks(_ base: URL) throws {
    let fm = FileManager.default
    let root = base.appendingPathComponent("store")
    let resources = base.appendingPathComponent("resources")
    let build = base.appendingPathComponent("build")
    for directory in [root, resources, build] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func check(_ condition: Bool, _ message: String) { precondition(condition, "CHECK FAILED: " + message) }
    for schema in ["rime_ice", "luna_pinyin"] {
        try Data("schema: fixture".utf8).write(to: build.appendingPathComponent("\(schema).schema.yaml"))
    }
    try Data("schema_list:\n  - schema: rime_ice\n  - schema: luna_pinyin\n".utf8)
        .write(to: build.appendingPathComponent("default.yaml"))
    let ice = PublishedKeyboard(schemaID: "rime_ice", layout: .qwerty26)
    let lunaInA = PublishedKeyboard(schemaID: "luna_pinyin", layout: .qwerty26)
    let luna = PublishedKeyboard(schemaID: "luna_pinyin", layout: .qwerty26)
    let keyA = KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "pkg-a")!
    let keyB = KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "pkg-b")!
    func publish(_ package: String, _ keyboards: [PublishedKeyboard], revision: String) throws {
        try KeyboardRecipeStore.publish(
            resources: resources, compiledBuild: build, revision: revision, rootURL: root,
            kind: .userScheme, packageID: package, selectedSchemaID: keyboards[0].schemaID,
            layout: keyboards[0].layout, publishedKeyboards: keyboards)
    }
    try publish("pkg-a", [ice, lunaInA], revision: "a1")
    try publish("pkg-b", [luna], revision: "b1")
    let defaults = UserDefaults(suiteName: "private-switch-\(UUID().uuidString)")!
    func shared() -> KeyboardRecipeStore.Activation { try! KeyboardRecipeStore.activation(rootURL: root)! }
    func seen() -> KeyboardRecipeStore.Activation {
        try! KeyboardRecipeStore.effectiveActivation(defaults: defaults, rootURL: root)!
    }
    let onB = shared()
    check(onB.rosterKey == keyB, "the host app runs package B")
    let generationsBefore = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("versions").path).count

    // Without Full Access the keyboard switches to package A's kept generation.
    KeyboardRecipeStore.canWriteSharedContainer = false
    check(
        KeyboardRecipeStore.savePrivatePackageSwitch(
            rosterKey: keyA, keyboard: lunaInA, defaults: defaults, rootURL: root),
        "package A is kept, so the switch is possible")
    let switched = seen()
    check(switched.rosterKey == keyA && switched.selectedSchemaID == "luna_pinyin", "the keyboard reads package A")
    check(switched.generation == onB.keptGenerations?[keyA], "it reads the generation the host app keeps")
    check(switched.keptGenerations?[keyB] == onB.generation, "package B stays kept to switch back to")
    check(shared() == onB, "the shared record is untouched")
    check(
        try fm.contentsOfDirectory(atPath: root.appendingPathComponent("versions").path).count == generationsBefore,
        "no generation is copied")

    // A keyboard pick inside the switched-to package stacks on top.
    check(
        KeyboardRecipeStore.savePrivateSelection(
            schemaID: "rime_ice", layout: .qwerty26, board: nil, defaults: defaults, rootURL: root),
        "a pick inside package A")
    check(seen().rosterKey == keyA && seen().selectedSchemaID == "rime_ice", "the pick applies over the switch")

    // Switching back to the package the shared record names drops the switch.
    check(
        KeyboardRecipeStore.savePrivatePackageSwitch(
            rosterKey: keyB, keyboard: luna, defaults: defaults, rootURL: root),
        "switching back")
    check(seen() == onB, "back on the shared record")
    check(defaults.data(forKey: KeyboardRecipeStore.privatePackageSwitchKey) == nil, "nothing kept")
    check(defaults.data(forKey: KeyboardRecipeStore.privateSelectionKey) == nil, "no stale pick")

    // A host choice made afterwards wins.
    KeyboardRecipeStore.savePrivatePackageSwitch(rosterKey: keyA, keyboard: ice, defaults: defaults, rootURL: root)
    KeyboardRecipeStore.canWriteSharedContainer = true
    try publish("pkg-b", [luna], revision: "b2")
    KeyboardRecipeStore.canWriteSharedContainer = false
    check(seen().rosterKey == keyB, "a later host publication wins")
    check(defaults.data(forKey: KeyboardRecipeStore.privatePackageSwitchKey) == nil, "the stale switch is forgotten")

    // With Full Access back, the kept switch and pick become the shared record.
    KeyboardRecipeStore.savePrivatePackageSwitch(rosterKey: keyA, keyboard: ice, defaults: defaults, rootURL: root)
    KeyboardRecipeStore.savePrivateSelection(
        schemaID: "luna_pinyin", layout: .qwerty26, board: nil, defaults: defaults, rootURL: root)
    let expected = seen()
    KeyboardRecipeStore.canWriteSharedContainer = true
    KeyboardRecipeStore.promotePrivateChoices(defaults: defaults, rootURL: root)
    let promoted = shared()
    check(
        promoted.rosterKey == keyA && promoted.selectedSchemaID == "luna_pinyin"
            && promoted.generation == expected.generation,
        "the shared record now holds the keyboard's choice")
    check(defaults.data(forKey: KeyboardRecipeStore.privatePackageSwitchKey) == nil, "the switch is forgotten")
    check(defaults.data(forKey: KeyboardRecipeStore.privateSelectionKey) == nil, "the pick is forgotten")
    check(seen() == promoted, "and the keyboard sees what the host app sees")
    print("private package switch checks passed")
}
