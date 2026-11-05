import Foundation

@main struct BuiltinScriptDefaultProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let schemas = ["songyan_quanpin", "songyan_flypy"]
        let firstInstall = BuiltinScriptBootstrapEvidence(hostEra: .current)
        let existingInstall = BuiltinScriptBootstrapEvidence(hostEra: .legacy)
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func hex(_ value: String) -> String {
            value.utf8.map { String(format: "%02x", $0) }.joined()
        }
        func choiceFile(_ store: OptionStore, schema: String) -> URL {
            store.directory
                .appendingPathComponent(hex("songyan-builtin"), isDirectory: true)
                .appendingPathComponent(hex(schema), isDirectory: true)
                .appendingPathComponent(hex("simplification") + ".json")
        }
        // The production store adapter the keyboard boot calls: the probe never builds its own read
        // or write closure, so this path is the one the Session runs.
        func realSeed(
            _ store: OptionStore, evidence: BuiltinScriptBootstrapEvidence, localeTags: [String],
            resourceID: String = "songyan-builtin", schemaIDs: [String]
        ) -> BuiltinScriptDefault.SeedOutcome? {
            store.seedBuiltinScriptDefault(
                evidence: evidence, localeTags: localeTags, resourceID: resourceID, schemaIDs: schemaIDs)
        }
        func writtenChoice(_ store: OptionStore, schema: String, state: BuiltinScriptState) throws -> Bool? {
            try store.value(
                for: BuiltinScriptDefault.descriptor(
                    resourceID: "songyan-builtin", schemaID: schema, state: state))
        }

        // A first install on a Taiwan locale persists exactly one of the four states per scheme.
        let taiwanStore = OptionStore(directory: try directory("new-taiwan"))
        let written = realSeed(taiwanStore, evidence: firstInstall, localeTags: ["zh-Hant-TW"], schemaIDs: schemas)
        check(written?.state == .taiwan, "a new zh-Hant-TW install starts in 臺灣")
        for schema in schemas {
            var chosen: [String] = []
            for state in BuiltinScriptState.allCases {
                if try writtenChoice(taiwanStore, schema: schema, state: state) == true {
                    chosen.append(state.optionName)
                }
            }
            // Reopening with a fresh store is the restart/scheme-switch read path.
            check(chosen == ["zh_tw"], "reopened \(schema) keeps exactly 臺灣")
        }

        // An existing install is never replaced, even though it has no saved script choice yet: the
        // rule returns before writing, so the real store stays empty.
        let existingDirectory = try directory("existing")
        let existingOutcome = realSeed(
            OptionStore(directory: existingDirectory), evidence: existingInstall,
            localeTags: ["zh-Hant-TW"], schemaIDs: schemas)
        check(existingOutcome == nil, "an existing install is never re-seeded")
        check(
            try FileManager.default.contentsOfDirectory(atPath: existingDirectory.path).isEmpty,
            "an existing install writes no switch file")

        // A non-Hant locale persists the simplified member under the group's first option name.
        let simplifiedStore = OptionStore(directory: try directory("new-simplified"))
        let state = realSeed(
            simplifiedStore, evidence: firstInstall, localeTags: ["en-US"], schemaIDs: ["songyan_quanpin"])
        check(state?.state == .simplified, "a simplified locale keeps 简体")
        check(
            try writtenChoice(simplifiedStore, schema: "songyan_quanpin", state: .simplified) == true,
            "简体 is stored under the group's first member (simplification)")

        // Region/script coverage at the write layer, including an explicit simplified script.
        for (tag, expected) in [
            ("zh-HK", BuiltinScriptState.hongKong), ("zh-MO", .hongKong),
            ("zh-Hant-US", .traditional), ("zh-Hans-TW", .simplified),
        ] {
            let store = OptionStore(directory: try directory("locale-" + tag))
            let seeded = realSeed(store, evidence: firstInstall, localeTags: [tag], schemaIDs: ["songyan_quanpin"])
            check(seeded?.state == expected, "\(tag) seeds \(expected.optionName)")
        }

        // A host legacy era and the extension's own pre-switch data both keep the old script: the
        // rule returns before writing, so the real stores stay empty.
        let hostLegacyStore = OptionStore(directory: try directory("host-legacy"))
        let hostLegacy = realSeed(
            hostLegacyStore, evidence: existingInstall, localeTags: ["zh-Hant-TW"], schemaIDs: schemas)
        check(hostLegacy == nil, "a host legacy install is never seeded")
        check(
            try FileManager.default.contentsOfDirectory(atPath: hostLegacyStore.directory.path).isEmpty,
            "a host legacy install writes no switch file")

        let localLegacyStore = OptionStore(directory: try directory("local-legacy"))
        let localLegacy = realSeed(
            localLegacyStore, evidence: BuiltinScriptBootstrapEvidence(hasLegacyLocalData: true),
            localeTags: ["zh-Hant-TW"], schemaIDs: schemas)
        check(localLegacy == nil, "the extension's own pre-switch data keeps the old value")
        check(
            try FileManager.default.contentsOfDirectory(atPath: localLegacyStore.directory.path).isEmpty,
            "the extension's legacy data writes no switch file")

        // A stored choice always wins over every migration input, judged by the real files: the
        // stored 臺灣 survives a locale that would seed 香港, and an old install writes nothing.
        let keptChoiceStore = OptionStore(directory: try directory("kept-choice"))
        let taiwanChoice = BuiltinScriptDefault.descriptor(
            resourceID: "songyan-builtin", schemaID: "songyan_quanpin", state: .taiwan)
        try keptChoiceStore.save(true, for: taiwanChoice)
        _ = realSeed(
            keptChoiceStore, evidence: firstInstall, localeTags: ["zh-Hant-HK"],
            schemaIDs: ["songyan_quanpin"])
        check(try keptChoiceStore.value(for: taiwanChoice) == true, "a stored choice keeps 臺灣")
        check(
            try writtenChoice(keptChoiceStore, schema: "songyan_quanpin", state: .hongKong) == false,
            "a stored choice is never replaced by the locale")
        let legacyNoChoice = OptionStore(directory: try directory("legacy-no-choice"))
        _ = realSeed(legacyNoChoice, evidence: existingInstall, localeTags: ["zh-Hant-TW"], schemaIDs: schemas)
        check(
            try FileManager.default.contentsOfDirectory(atPath: legacyNoChoice.directory.path).isEmpty,
            "an old install with no choice writes nothing")

        // The host's current era is not evidence of an old install.
        check(
            TraditionalDefault.seedState(for: firstInstall, localeTags: ["zh-Hant-TW"]) == .taiwan,
            "a current-era fresh install still gets the locale seed")

        // Without Full Access the App Group is readable but not writable: the choice must persist in
        // the extension's own container and the same store must read it back.
        let blocked = root.appendingPathComponent("blocked-shared")
        try Data().write(to: blocked)
        let privateStore = try directory("no-full-access-private")
        let dual = OptionStore(directory: blocked, fallbackDirectory: privateStore)
        let taiwanOnQuanpin = BuiltinScriptDefault.descriptor(
            resourceID: "songyan-builtin", schemaID: "songyan_quanpin", state: .taiwan)
        try dual.save(true, for: taiwanOnQuanpin)
        check(
            try OptionStore(directory: blocked, fallbackDirectory: privateStore)
                .value(for: taiwanOnQuanpin) == true,
            "a no-Full-Access save persists in the private container and reads back")
        check(
            try OptionStore(directory: blocked).value(for: taiwanOnQuanpin) == nil,
            "the blocked shared store never holds the private choice")

        // The boot path without Full Access: the production rule seeds through a store whose shared
        // directory refuses writes, so the choice lands in this process's container and reads back.
        let bootBlockedShared = root.appendingPathComponent("boot-blocked-shared")
        try Data().write(to: bootBlockedShared)
        let bootPrivate = try directory("boot-private")
        let bootStore = OptionStore(directory: bootBlockedShared, fallbackDirectory: bootPrivate)
        let bootOutcome = realSeed(bootStore, evidence: firstInstall, localeTags: ["zh-Hant-TW"], schemaIDs: schemas)
        check(bootOutcome?.state == .taiwan, "a first install without Full Access seeds 臺灣")
        check(bootOutcome?.isComplete == true, "both built-in schemes keep the private choice")
        let bootDescriptor = BuiltinScriptDefault.descriptor(
            resourceID: "songyan-builtin", schemaID: "songyan_flypy", state: .taiwan)
        check(
            try OptionStore(directory: bootBlockedShared, fallbackDirectory: bootPrivate)
                .value(for: bootDescriptor) == true,
            "the engine reads the private seed back through the same store")
        check(
            try OptionStore(directory: bootBlockedShared).value(for: bootDescriptor) == nil,
            "the Host's shared store never sees the private seed")

        // The shared choice wins when both stores hold one (Full Access restored).
        let sharedWritable = try directory("shared-writable")
        let sharedStore = OptionStore(directory: sharedWritable, fallbackDirectory: privateStore)
        try sharedStore.save(true, for: taiwanOnQuanpin)
        let conflicting = OptionStore(directory: privateStore)
        try conflicting.save(
            true,
            for: BuiltinScriptDefault.descriptor(
                resourceID: "songyan-builtin", schemaID: "songyan_quanpin", state: .simplified))
        let stalePrivateFile = choiceFile(OptionStore(directory: privateStore), schema: "songyan_quanpin")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: stalePrivateFile.path)
        check(
            try sharedStore.value(for: taiwanOnQuanpin) == true,
            "an older private fallback never shadows the shared choice")

        // Shared holds an old choice while a read-only App Group forces a newer one into the private
        // fallback: the newer explicit choice must be the one read back (not silently lost).
        let sharedOld = try directory("shared-old")
        let privateNew = try directory("private-new")
        let oldDescriptor = BuiltinScriptDefault.descriptor(
            resourceID: "songyan-builtin", schemaID: "songyan_quanpin", state: .simplified)
        let newerDescriptor = BuiltinScriptDefault.descriptor(
            resourceID: "songyan-builtin", schemaID: "songyan_quanpin", state: .taiwan)
        try OptionStore(directory: sharedOld).save(true, for: oldDescriptor)
        try OptionStore(directory: privateNew).save(true, for: newerDescriptor)
        let sharedFile = choiceFile(OptionStore(directory: sharedOld), schema: "songyan_quanpin")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: sharedFile.path)
        let mixed = OptionStore(directory: sharedOld, fallbackDirectory: privateNew)
        check(try mixed.value(for: oldDescriptor) == false, "the older shared choice is not reported as on")
        check(
            try mixed.value(for: newerDescriptor) == true,
            "a newer private choice wins over the older shared one")

        // With Full Access restored, a save goes to the shared store and clears the stale private copy.
        let writableShared = try directory("shared-restored")
        let restored = OptionStore(directory: writableShared, fallbackDirectory: privateNew)
        try restored.save(true, for: newerDescriptor)
        check(try restored.value(for: newerDescriptor) == true, "a full-access save keeps the choice")
        check(
            !FileManager.default.fileExists(
                atPath: choiceFile(OptionStore(directory: privateNew), schema: "songyan_quanpin").path),
            "a full-access save removes the stale private copy")

        // Migration moves a private choice made without Full Access into the shared store once.
        let migrateShared = try directory("migrate-shared")
        let migratePrivate = try directory("migrate-private")
        try OptionStore(directory: migrateShared).save(true, for: oldDescriptor)
        try OptionStore(directory: migratePrivate).save(true, for: newerDescriptor)
        let migrateSharedFile = choiceFile(OptionStore(directory: migrateShared), schema: "songyan_quanpin")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: migrateSharedFile.path)
        OptionStore(directory: migrateShared, fallbackDirectory: migratePrivate).migrateFallbackToShared()
        check(
            try OptionStore(directory: migrateShared).value(for: newerDescriptor) == true,
            "migration brings the newer private choice into the shared store")

        // A fresh host publishes its first selection before the keyboard boots: with a current-era
        // record that selection must not make the install look upgraded.
        check(
            TraditionalDefault.seedState(
                for: BuiltinScriptBootstrapEvidence(hostEra: .current, hasPriorSharedData: true),
                localeTags: ["zh-Hant-TW"]) == .taiwan,
            "the host's current-run selection does not block a fresh seed")
        check(
            TraditionalDefault.seedState(
                for: BuiltinScriptBootstrapEvidence(hasPriorSharedData: true), localeTags: ["zh-Hant-TW"]) == nil,
            "shared data without an era record keeps an old install untouched")
        check(
            TraditionalDefault.seedState(
                for: BuiltinScriptBootstrapEvidence(hostEra: .current, hasLegacyLocalData: true),
                localeTags: ["zh-Hant-TW"]) == nil,
            "the process's own old data still wins over a current-era label")

        // The real fallback factory id ("builtin") and the installed package id are one scheme: a
        // seed written through the fallback id is read back through the package id from real files.
        check(
            BuiltinScriptIdentity.isBuiltin("builtin") && BuiltinScriptIdentity.isBuiltin("songyan-builtin"),
            "both built-in resource ids are recognized")
        let fallbackStore = OptionStore(directory: try directory("fallback-identity"))
        let fallbackOutcome = realSeed(
            fallbackStore, evidence: firstInstall, localeTags: ["zh-Hant-TW"],
            resourceID: BuiltinScriptIdentity.optionStoreResourceID("builtin"),
            schemaIDs: ["songyan_quanpin"])
        check(fallbackOutcome?.state == .taiwan, "the fallback id seeds the locale state")
        check(
            try writtenChoice(fallbackStore, schema: "songyan_quanpin", state: .taiwan) == true,
            "a fallback-id seed reads back under the installed package id")
        check(
            try fallbackStore.value(
                for: BuiltinScriptDefault.descriptor(
                    resourceID: "builtin", schemaID: "songyan_quanpin", state: .taiwan)) == nil,
            "the unnormalized fallback key holds nothing: the mapping is what unifies them")

        // A real file where the store needs a schema directory: that write fails, and the seed
        // reports the schema instead of claiming it. The other schema still lands on disk.
        let obstructedStore = OptionStore(directory: try directory("write-failure"))
        let obstructedResource = obstructedStore.directory
            .appendingPathComponent(hex("songyan-builtin"), isDirectory: true)
        try FileManager.default.createDirectory(at: obstructedResource, withIntermediateDirectories: true)
        try Data().write(to: obstructedResource.appendingPathComponent(hex("songyan_flypy")))
        let obstructed = realSeed(
            obstructedStore, evidence: firstInstall, localeTags: ["zh-Hant-TW"], schemaIDs: schemas)
        check(obstructed?.state == .taiwan, "a blocked schema does not stop the locale decision")
        check(obstructed?.seededSchemaIDs == ["songyan_quanpin"], "the writable schema is seeded")
        check(obstructed?.failedSchemaIDs == ["songyan_flypy"], "the blocked schema is reported, not claimed")
        check(obstructed?.isComplete == false, "a failed write makes the seed incomplete")
        check(
            try writtenChoice(obstructedStore, schema: "songyan_quanpin", state: .taiwan) == true,
            "the seeded schema reads back 臺灣")
        check(
            try writtenChoice(obstructedStore, schema: "songyan_flypy", state: .taiwan) == nil,
            "the blocked schema holds no choice")

        // A saved choice that cannot be read is unknown, never "no choice": the seed must leave the
        // file untouched, report that schema, and still seed the other input method.
        let corruptStore = OptionStore(directory: try directory("corrupt-choice"))
        let corruptFile = choiceFile(corruptStore, schema: "songyan_quanpin")
        try FileManager.default.createDirectory(
            at: corruptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corruptBytes = Data("{ not a saved choice".utf8)
        try corruptBytes.write(to: corruptFile)
        let corruptOutcome = realSeed(
            corruptStore, evidence: firstInstall, localeTags: ["zh-Hant-TW"], schemaIDs: schemas)
        check(
            corruptOutcome?.failedSchemaIDs == ["songyan_quanpin"],
            "an unreadable saved choice is reported as failed")
        check(corruptOutcome?.seededSchemaIDs == ["songyan_flypy"], "the other input method still seeds")
        check(
            try Data(contentsOf: corruptFile) == corruptBytes,
            "an unreadable saved choice is never overwritten")
        check(corruptOutcome?.isComplete == false, "a read failure makes the seed incomplete")

        let unreadableStore = OptionStore(directory: try directory("unreadable-choice"))
        let unreadableFile = choiceFile(unreadableStore, schema: "songyan_quanpin")
        try FileManager.default.createDirectory(
            at: unreadableFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let keptBytes = Data("\"zh_tw\"".utf8)
        try keptBytes.write(to: unreadableFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableFile.path)
        let unreadableOutcome = realSeed(
            unreadableStore, evidence: firstInstall, localeTags: ["zh-Hant-TW"], schemaIDs: schemas)
        check(
            unreadableOutcome?.failedSchemaIDs == ["songyan_quanpin"],
            "a permission-denied saved choice is reported as failed")
        check(
            unreadableOutcome?.seededSchemaIDs == ["songyan_flypy"],
            "the other input method still seeds while a choice is unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableFile.path)
        check(
            try Data(contentsOf: unreadableFile) == keptBytes,
            "a permission-denied saved choice is never overwritten")

        print("builtin script default bootstrap checks passed")
    }

    private static func check(_ condition: Bool, _ label: String) {
        if !condition { fatalError("FAIL: " + label) }
        print("PASS: " + label)
    }
}
