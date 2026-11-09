import Foundation

func keptPackagesChecks(_ base: URL) throws {
    let fm = FileManager.default
    let root = base.appendingPathComponent("store")
    let resources = base.appendingPathComponent("resources")
    let build = base.appendingPathComponent("build")
    for d in [root, resources, build] {
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
    }
    func check(_ condition: Bool, _ message: String) { precondition(condition, "CHECK FAILED: " + message) }
    func refuses(_ message: String, _ action: () throws -> Void) {
        do {
            try action()
            fatalError("expected refusal: " + message)
        } catch {}
    }
    let schemaIDs = ["rime_ice", "luna_pinyin", "stroke", "bopomofo"]
    try Data(("schema_list:\n" + schemaIDs.map { "  - schema: \($0)\n" }.joined()).utf8)
        .write(to: build.appendingPathComponent("default.yaml"))
    for s in schemaIDs {
        try Data("schema: fixture".utf8).write(to: build.appendingPathComponent("\(s).schema.yaml"))
    }
    let schemas = [
        KeyboardSchemaDescriptor(id: "rime_ice", name: "通用全拼", alphabet: "abcdefghijklmnopqrstuvwxyz"),
        KeyboardSchemaDescriptor(id: "luna_pinyin", name: "朙月拼音", alphabet: "abcdefghijklmnopqrstuvwxyz"),
        KeyboardSchemaDescriptor(id: "stroke", name: "笔画", alphabet: "abcdefghijklmnopqrstuvwxyz"),
        KeyboardSchemaDescriptor(id: "bopomofo", name: "注音", alphabet: "abcdefghijklmnopqrstuvwxyz"),
    ]
    let ice = PublishedKeyboard(schemaID: "rime_ice", layout: .qwerty26)
    let luna = PublishedKeyboard(schemaID: "luna_pinyin", layout: .qwerty26)
    let stroke = PublishedKeyboard(schemaID: "stroke", layout: .qwerty26)
    let keyA = KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "pkg-a")!
    let keyB = KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "pkg-b")!
    let keyC = KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "pkg-c")!
    func publish(_ package: String, _ keyboards: [PublishedKeyboard], revision: String) throws
        -> KeyboardRecipeStore.Activation
    {
        try KeyboardRecipeStore.publish(
            resources: resources, compiledBuild: build, revision: revision, rootURL: root,
            kind: .userScheme, dictionaryName: "Name-" + package, packageID: package, schemas: schemas,
            selectedSchemaID: keyboards.first?.schemaID, layout: keyboards.first?.layout,
            publishedKeyboards: keyboards)
        return try KeyboardRecipeStore.activation(rootURL: root)!
    }
    func generationExists(_ generation: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent("versions/\(generation)").path)
    }

    // (a) Keep set: every package with added keyboards keeps its generation; others are reclaimed.
    let a1 = try publish("pkg-a", [ice], revision: "a1")
    check(a1.keptGenerations == [keyA: a1.generation], "first publication keeps itself")
    check(
        fm.fileExists(atPath: root.appendingPathComponent("versions/\(a1.generation)/activation.json").path),
        "generation record written")
    let b1 = try publish("pkg-b", [luna, stroke], revision: "b1")
    check(b1.keptGenerations == [keyA: a1.generation, keyB: b1.generation], "second package keeps both")
    let b2 = try publish("pkg-b", [luna, stroke], revision: "b2")
    check(b2.keptGenerations == [keyA: a1.generation, keyB: b2.generation], "republish replaces its own entry")
    check(generationExists(a1.generation), "package A generation survives two later publications")
    check(generationExists(b2.generation) && generationExists(b1.generation), "new and previous generation kept")
    let b3 = try publish("pkg-b", [luna], revision: "b3")
    check(!generationExists(b1.generation), "replaced generation reclaimed")
    check(generationExists(b2.generation), "previous generation kept")
    check(
        KeyboardRecipeStore.generationRecord(generation: a1.generation, rootURL: root)?.packageID == "pkg-a",
        "generation record readable")

    // Empty roster keeps nothing for that package.
    let c1 = try publish("pkg-c", [stroke], revision: "c1")
    check(c1.keptGenerations?[keyC] == c1.generation, "package C kept while it has a keyboard")
    let emptied = try KeyboardRecipeStore.activation(rootURL: root)!
    var cleared = emptied
    cleared.keyboardsBySource?[keyC] = []
    try canonicalJSONEncoder().encode(cleared).write(to: root.appendingPathComponent("active.json"))
    let b4 = try publish("pkg-b", [luna], revision: "b4")
    check(b4.keptGenerations?[keyC] == nil, "empty roster drops the entry")
    check(generationExists(c1.generation), "the replaced record's generation is still the previous one")
    check(b4.keptGenerations?[keyA] == a1.generation, "other package unaffected")

    // A kept generation without its record is dropped, not trusted.
    try fm.removeItem(at: root.appendingPathComponent("versions/\(a1.generation)/activation.json"))
    let b5 = try publish("pkg-b", [luna], revision: "b5")
    check(!generationExists(c1.generation), "empty roster generation reclaimed once no longer previous")
    check(b5.keptGenerations?[keyA] == nil, "missing record drops the entry")
    check(!generationExists(a1.generation), "missing record generation reclaimed")
    _ = b3

    // (b) activateKeptPackage: rebuild A, then switch from B to A and back.
    let a2 = try publish("pkg-a", [ice], revision: "a2")
    let b6 = try publish("pkg-b", [luna, stroke], revision: "b6")
    check(b6.keptGenerations?[keyA] == a2.generation, "A kept again")
    refuses("stale generation") {
        try KeyboardRecipeStore.activateKeptPackage(
            rosterKey: keyA, keyboard: ice, expectedGeneration: "old", rootURL: root)
    }
    refuses("current package") {
        try KeyboardRecipeStore.activateKeptPackage(
            rosterKey: keyB, keyboard: luna, expectedGeneration: b6.generation, rootURL: root)
    }
    refuses("unknown package") {
        try KeyboardRecipeStore.activateKeptPackage(
            rosterKey: keyC, keyboard: ice, expectedGeneration: b6.generation, rootURL: root)
    }
    refuses("keyboard outside the roster") {
        try KeyboardRecipeStore.activateKeptPackage(
            rosterKey: keyA, keyboard: luna, expectedGeneration: b6.generation, rootURL: root)
    }
    KeyboardRecipeStore.canWriteSharedContainer = false
    refuses("read-only container") {
        try KeyboardRecipeStore.activateKeptPackage(
            rosterKey: keyA, keyboard: ice, expectedGeneration: b6.generation, rootURL: root)
    }
    KeyboardRecipeStore.canWriteSharedContainer = true
    check(try KeyboardRecipeStore.activation(rootURL: root) == b6, "refusals changed nothing")
    try KeyboardRecipeStore.setEnabled(false, rootURL: root)
    let builtinRecord = try KeyboardRecipeStore.activation(rootURL: root)!
    check(!builtinRecord.recipeEnabled && builtinRecord.generation == b6.generation, "built-in record")
    try KeyboardRecipeStore.setEnabled(true, rootURL: root)

    try KeyboardRecipeStore.activateKeptPackage(
        rosterKey: keyA, keyboard: ice, expectedGeneration: b6.generation, rootURL: root)
    let onA = try KeyboardRecipeStore.activation(rootURL: root)!
    check(onA.generation == a2.generation && onA.recipeEnabled, "A is active on its own generation")
    check(onA.packageID == "pkg-a" && onA.publishedKeyboards == [ice], "A list is its remembered roster")
    check(onA.selectedKeyboard == ice, "requested keyboard selected")
    check(onA.keyboardsBySource?[keyB] == [luna, stroke], "left package's roster recorded under its key")
    check(onA.keptGenerations == [keyB: b6.generation], "left package kept, target entry removed")
    check(generationExists(b6.generation) && generationExists(a2.generation), "nothing deleted")
    try KeyboardRecipeStore.activateKeptPackage(
        rosterKey: keyB, keyboard: stroke, expectedGeneration: onA.generation, rootURL: root)
    let backOnB = try KeyboardRecipeStore.activation(rootURL: root)!
    check(backOnB.generation == b6.generation && backOnB.selectedKeyboard == stroke, "switched back")
    check(backOnB.keptGenerations == [keyA: a2.generation], "A kept after the way back")
    check(backOnB.keyboardsBySource?[keyA] == [ice], "A roster still remembered")

    // (c) Entry list.
    let records: (String) -> KeyboardRecipeStore.Activation? = {
        KeyboardRecipeStore.generationRecord(generation: $0, rootURL: root)
    }
    let running = KeyboardRecipeStore.otherPackageKeyboards(
        from: backOnB, builtinRunning: false, canWrite: true, record: records)
    check(running.count == 2, "one kept keyboard plus the built-in entry")
    check(running[0].target == .keptPackage(rosterKey: keyA) && running[0].keyboard == ice, "kept entry target")
    check(
        running[0].packageName == "Name-pkg-a" && running[0].title == "通用全拼 · 26 键",
        "kept entry names: \(running[0].title)")
    check(running[0].id.hasPrefix(OtherPackageKeyboard.capIDPrefix), "cap id prefix")
    check(running[1].target == .builtin && running[1].keyboard == nil, "built-in entry last")
    check(Set(running.map(\.id)).count == running.count, "entry ids unique")
    let readOnly = KeyboardRecipeStore.otherPackageKeyboards(
        from: backOnB, builtinRunning: false, canWrite: false, record: records)
    check(readOnly.map(\.target) == [.builtin], "without Full Access only the built-in entry")
    let none = KeyboardRecipeStore.otherPackageKeyboards(
        from: backOnB, builtinRunning: false, canWrite: true, record: { _ in nil })
    check(none.map(\.target) == [.builtin], "a kept package without a record is left out")
    var emptyRoster = backOnB
    emptyRoster.keyboardsBySource?[keyA] = []
    check(
        KeyboardRecipeStore.otherPackageKeyboards(
            from: emptyRoster, builtinRunning: false, canWrite: true, record: records
        ).map(\.target) == [.builtin],
        "an empty roster is left out")
    var sameSource = backOnB
    sameSource.keptGenerations?[keyB] = b6.generation
    check(
        KeyboardRecipeStore.otherPackageKeyboards(
            from: sameSource, builtinRunning: false, canWrite: true, record: records
        ).allSatisfy { $0.target != .keptPackage(rosterKey: keyB) },
        "the running package is never listed as another")
    let onBuiltin = KeyboardRecipeStore.otherPackageKeyboards(
        from: backOnB.withEnabled(false), builtinRunning: true, canWrite: true, record: records)
    check(
        onBuiltin.map(\.target) == [.recordedPackage, .recordedPackage, .keptPackage(rosterKey: keyA)],
        "built-in running: recorded package's keyboards, then kept ones, no built-in entry")
    check(onBuiltin[0].packageName == "Name-pkg-b", "recorded package name")
    check(
        KeyboardRecipeStore.otherPackageKeyboards(
            from: nil, builtinRunning: true, canWrite: true, record: records
        ).isEmpty,
        "no record, no entries")

    // A keyboard without a saved board is named by the board its family types on.
    let keyD = KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "pkg-d")!
    _ = try publish("pkg-d", [PublishedKeyboard(schemaID: "bopomofo", layout: .qwerty26)], revision: "d1")
    let fromB = try publish("pkg-b", [luna], revision: "b7")
    let zhuyin = KeyboardRecipeStore.otherPackageKeyboards(
        from: fromB, builtinRunning: false, canWrite: true, record: records
    ).first { $0.target == .keptPackage(rosterKey: keyD) }
    let zhuyinBoard = UserTerminology.builtinLayoutName(physicalLayoutID: "zhuyin41")!
    check(zhuyin?.title == "注音 · " + zhuyinBoard, "zhuyin entry names its own board: \(zhuyin?.title ?? "-")")

    // (d) Records written before kept generations existed decode without the field.
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backOnB)) as! [String: Any]
    object.removeValue(forKey: "keptGenerations")
    let legacy = try JSONDecoder().decode(
        KeyboardRecipeStore.Activation.self, from: JSONSerialization.data(withJSONObject: object))
    check(legacy.keptGenerations == nil && legacy.generation == backOnB.generation, "legacy record decodes")

    print("PASS: kept package generations, activation and entry list")
}
