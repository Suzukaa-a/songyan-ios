import Foundation
import KeyboardCore
import RimeKit
import os

/// Cross-process handoff contains immutable deployed resources, never a live user database.
public enum KeyboardRecipeStore {
    public enum ResourceKind: String, Codable, Sendable {
        case userDictionary, userScheme
    }

    /// The structured roster key of a source (the dictionary key of the cross-source keyboard cache).
    ///
    /// The key is built only from the structured source identity and never contains a schema name,
    /// brand, recipe, path or hash. Validity and format are defined in one place by
    /// `PublishedKeyboardSourceKey` (KeyboardCore); non-ASCII/Chinese package identities admitted at
    /// install time work too (the key is only a dictionary key, not a disk path). Returns nil when the identity is missing.
    public static func rosterKey(kind: ResourceKind, packageID: String?) -> String? {
        switch kind {
        case .userDictionary: return KeyboardPublicationSource.userDictionary.cacheKey
        case .userScheme:
            guard let packageID else { return nil }
            return KeyboardPublicationSource.userScheme(packageID: packageID).cacheKey
        }
    }

    /// Roster key for a structured source identity (same format as `rosterKey(kind:packageID:)`).
    public static func rosterKey(_ source: KeyboardPublicationSource) -> String? {
        source.cacheKey
    }

    public struct Activation: Codable, Equatable, Sendable {
        public let generation: String
        public let revision: String
        public var recipeEnabled: Bool
        public let publishedAt: Date
        public var resourceKind: ResourceKind
        public var dictionaryName: String? = nil
        public var packageID: String? = nil
        public var schemas: [KeyboardSchemaDescriptor]? = nil
        public var selectedSchemaID: String? = nil
        public var selectedLayout: KeyboardLayoutKind? = nil
        /// The physical board of the selected keyboard (see `PublishedKeyboard.board`); nil = from the pairing.
        public var selectedBoard: String? = nil
        public var schemaBindings: [KeyboardResourceSet.LayoutEntry]? = nil
        public var hostInstallationGeneration: String? = nil
        /// The "user keyboards" list that has been added (publication unit = input method + layout).
        /// nil means no keyboard has been added; combinations are never invented from the selection.
        /// The extension only reads it to build the switch list.
        public var publishedKeyboards: [PublishedKeyboard]? = nil
        /// The full keyboard list last successfully published for each source (key = structured source identity, see `rosterKey`).
        ///
        /// `publishedKeyboards` is always only the current source's list (so the extension's runtime
        /// validation sees only this source and never mixes in others); this field additionally keeps
        /// the full lists of other sources as the authoritative baseline when switching back to an
        /// earlier source.
        public var keyboardsBySource: [String: [PublishedKeyboard]]? = nil
        /// Explicit auxiliary English candidate routes, each owned by one exact published pair.
        /// Never inferred from enabled dependencies.
        public var englishCandidateRoutes: [EnglishCandidateRoute]? = nil
        /// Prepared generations kept for packages other than the running one (key = `rosterKey`).
        /// Each has its own `activation.json`, so the keyboard can switch to it without the host app.
        /// Only packages that still have at least one added keyboard keep a generation.
        public var keptGenerations: [String: String]? = nil
        public var kind: ResourceKind { resourceKind }
        /// The published identity of the selected keyboard, board included.
        public var selectedKeyboard: PublishedKeyboard? {
            guard let selectedSchemaID, let selectedLayout else { return nil }
            return PublishedKeyboard(schemaID: selectedSchemaID, layout: selectedLayout, board: selectedBoard)
        }
        /// Source display name (not the input-method name).
        public var name: String {
            dictionaryName ?? packageID ?? String(localized: "用户方案")
        }
        /// Configuration-level display name (home page / scheme list): an imported dictionary maps to
        /// the "custom pinyin" configuration, and the dictionary name (a resource name, possibly any
        /// English file name from the user) is not used as the configuration name.
        /// Source identity and input method are separate dimensions: this property only gives the source name.
        public var displayConfigName: String {
            switch kind {
            case .userDictionary: return String(localized: "自定义拼音")
            case .userScheme: return dictionaryName ?? packageID ?? String(localized: "用户方案")
            }
        }
        /// One authoritative OptionStore namespace, shared by Host settings and every runtime.
        public var resourceID: String {
            switch kind {
            case .userDictionary: return "user-pinyin"
            case .userScheme: return packageID ?? generation
            }
        }
        public var requiredSchemaIDs: [String] { schemas?.map(\.id) ?? [] }

        /// The published keyboard list (the only source for the extension's switch list).
        public var keyboards: [PublishedKeyboard] {
            PublishedKeyboard.resolve(published: publishedKeyboards)
        }

        /// Whether a keyboard of any input scheme in 我的键盘 names this layout as the one it types on.
        public func hasKeyboard(namingLayout id: String) -> Bool {
            keyboards.contains { $0.board == id }
                || (keyboardsBySource ?? [:]).values.contains { $0.contains { $0.board == id } }
        }

        /// Whether this record forces showing only added keyboards: true with an explicit list or a
        /// selection; a record with neither (built-in pinyin) keeps every bundled combination.
        public var enforcesPublishedKeyboards: Bool {
            publishedKeyboards != nil || selectedSchemaID != nil
        }

        /// The structured source identity (provenance) of the record. Used to decide publication
        /// ownership when an install is deleted; never guessed from schema strings. nil when no valid identity can be formed (e.g. a userScheme without a package identity).
        public var publicationSource: KeyboardPublicationSource? {
            switch kind {
            case .userDictionary: return .userDictionary
            case .userScheme:
                guard let packageID, !packageID.isEmpty else { return nil }
                return .userScheme(packageID: packageID)
            }
        }

        /// The structured roster key of this record's source: `kind` + `packageID` (unique, stable,
        /// independent of path/name). nil when no valid identity can be formed (no cross-source list is recorded then, and keys are never guessed).
        public var rosterKey: String? {
            KeyboardRecipeStore.rosterKey(kind: kind, packageID: packageID)
        }

        /// A copy of the same publication record with a different enabled state: keeps all publication
        /// metadata (generation / revision / source identity / `schemas` / selection / bindings / added
        /// keyboard list, ...) and changes only `recipeEnabled`. Never rebuild field by field (that would drop fields such as `publishedKeyboards`).
        public func withEnabled(_ enabled: Bool) -> Activation {
            var copy = self
            copy.recipeEnabled = enabled
            return copy
        }
    }

    public struct Snapshot {
        public let activation: Activation
        public let resources: URL
        public let build: URL
        /// Stable runtime identity carried by the publication snapshot. Callers should
        /// preserve this value rather than reconstructing identity from a path spelling.
        public var selectionRuntimeIdentity: SelectionRuntimeIdentity {
            .published
        }
        public func resourceSet(userDirectory: URL) -> KeyboardResourceSet {
            if let selected = activation.selectedSchemaID {
                let templateBindings: [KeyboardResourceSet.LayoutEntry]
                switch activation.kind {
                case .userDictionary:
                    templateBindings = BuiltinTemplateSchemas.layoutEntries
                case .userScheme: templateBindings = []
                }
                return KeyboardResourceSet(
                    id: activation.resourceID,
                    name: activation.name, sharedDirectory: resources, userDirectory: userDirectory,
                    layoutEntries: activation.schemaBindings ?? templateBindings, prebuiltDirectory: build,
                    schemas: activation.schemas ?? activation.requiredSchemaIDs.map { .init(id: $0, name: $0) },
                    selectedSchemaID: selected, preferredLayout: activation.selectedLayout,
                    preferredBoard: activation.selectedBoard,
                    sourceRevision: activation.revision, publicationGeneration: activation.generation,
                    publishedKeyboards: activation.enforcesPublishedKeyboards ? activation.keyboards : nil,
                    englishCandidateRoutes: activation.englishCandidateRoutes ?? [])
            }
            switch activation.kind {
            case .userDictionary:
                return KeyboardResourceSet(
                    id: activation.resourceID, name: activation.name,
                    sharedDirectory: resources, userDirectory: userDirectory,
                    layoutEntries: BuiltinTemplateSchemas.layoutEntries,
                    prebuiltDirectory: build, schemas: activation.schemas ?? [],
                    sourceRevision: activation.revision, publicationGeneration: activation.generation,
                    publishedKeyboards: activation.enforcesPublishedKeyboards ? activation.keyboards : nil,
                    englishCandidateRoutes: activation.englishCandidateRoutes ?? [])
            case .userScheme:
                return KeyboardResourceSet(
                    id: activation.resourceID, name: activation.name,
                    sharedDirectory: resources, userDirectory: userDirectory,
                    layoutEntries: activation.schemaBindings ?? [], prebuiltDirectory: build,
                    schemas: activation.schemas ?? [], selectedSchemaID: activation.selectedSchemaID,
                    preferredLayout: activation.selectedLayout, preferredBoard: activation.selectedBoard,
                    sourceRevision: activation.revision,
                    publicationGeneration: activation.generation,
                    publishedKeyboards: activation.enforcesPublishedKeyboards ? activation.keyboards : nil,
                    englishCandidateRoutes: activation.englishCandidateRoutes ?? [])
            }
        }
    }

    public struct StoreError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Resolves the App Group container and creates the recipe directory. Writers use this; readers use `readRoot()`.
    public static func root() throws -> URL {
        guard let container = sharedContainerURL() else {
            throw StoreError(message: String(localized: "无法访问共享数据，请在系统设置中开启「允许完全访问」"))
        }
        let root = container.appendingPathComponent("KeyboardRecipes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw StoreError(message: String(localized: "共享存储空间无法读写，请检查存储权限与设备可用空间"))
        }
        return root
    }

    /// Process-level cached root for read-only paths: does not call `root()`, which creates directories.
    /// Caches only a successfully resolved system App Group URL; when the container is unavailable it is re-evaluated next time.
    private static let cachedReadRoot = OSAllocatedUnfairLock<URL?>(initialState: nil)

    public static func readRoot() throws -> URL {
        if let cached = cachedReadRoot.withLock({ $0 }) { return cached }
        guard let container = sharedContainerURL() else {
            throw StoreError(message: String(localized: "无法访问共享数据，请在系统设置中开启「允许完全访问」"))
        }
        let resolved = container.appendingPathComponent("KeyboardRecipes", isDirectory: true)
        cachedReadRoot.withLock { $0 = resolved }
        return resolved
    }

    /// One bounded read of the shared `active.json`; `snapshot(selection:)` parses these same bytes.
    public struct SelectionRead: Sendable {
        public let root: URL?
        /// The bytes read; nil when absent or unreadable.
        public let data: Data?
        /// Why the read failed (never silently treated as absent).
        public let readError: String?
    }

    public static func readSelection(rootURL: URL? = nil) -> SelectionRead {
        let root: URL
        do {
            root = try rootURL ?? readRoot()
        } catch {
            return SelectionRead(
                root: nil, data: nil,
                readError: String(localized: "共享存储空间不可用：\(error.localizedDescription)"))
        }
        let active = root.appendingPathComponent("active.json")
        switch BoundedFileRead.read(active) {
        case .success(let data):
            return SelectionRead(root: root, data: data, readError: nil)
        case .failure(.missing):
            return SelectionRead(root: root, data: nil, readError: nil)
        case .failure(.tooLarge(let size)):
            return SelectionRead(
                root: root, data: nil,
                readError: String(localized: "输入方案配置过大（\(size) 字节），已取消读取"))
        case .failure(.unreadable(let detail)):
            return SelectionRead(
                root: root, data: nil,
                readError: String(localized: "输入方案配置无法读取：\(detail)"))
        }
    }

    /// Whether the record still names the running engine's generation, input method and
    /// layout. Any missing field or decode failure returns false, so the caller re-resolves.
    public static func selection(_ selection: SelectionRead, matches running: KeyboardRouteKey) -> Bool {
        guard selection.readError == nil, let data = selection.data,
            let activation = try? JSONDecoder().decode(Activation.self, from: data),
            activation.recipeEnabled, !activation.generation.isEmpty,
            activation.generation == running.publicationGeneration,
            let source = activation.selectedSchemaID, source == running.sourceSchemaID,
            let layout = activation.selectedLayout, layout == running.layout,
            activation.selectedBoard == running.board
        else { return false }
        return true
    }

    public static func snapshot(selection: SelectionRead, selectedOnly: Bool = false) throws -> Snapshot? {
        if let readError = selection.readError {
            throw StoreError(message: String(localized: "无法读取已保存的输入方案配置：\(readError)"))
        }
        guard let root = selection.root, let data = selection.data else { return nil }
        // Single production resolve path: parse from the same immutable active.json bytes (identity and content share one source).
        let activation = try JSONDecoder().decode(Activation.self, from: data)
        if selectedOnly && !activation.recipeEnabled { return nil }
        if activation.generation.isEmpty && !activation.recipeEnabled { return nil }
        return try snapshot(for: activation, root: root)
    }

    /// active.json is the only persisted selection, shared by host and keyboard.
    /// A builtin selection before first publication uses an empty generation.
    ///
    /// Reads use the cached `readRoot()`; writers call `root()`.
    public static func activation(rootURL: URL? = nil) throws -> Activation? {
        let root = try rootURL ?? readRoot()
        let active = root.appendingPathComponent("active.json")
        // Same bounded read as `readSelection`: keyboard extension memory is limited, so an abnormally large shared file is not read whole into memory.
        switch BoundedFileRead.read(active) {
        case .success(let data):
            return try JSONDecoder().decode(Activation.self, from: data)
        case .failure(.missing):
            return nil
        case .failure(let error):
            throw StoreError(message: String(localized: "无法读取已保存的输入方案配置：\(String(describing: error))"))
        }
    }

    /// The record a write starts from. A damaged or unreadable record counts as missing, so
    /// switching to built-in or publishing a scheme replaces it instead of failing on it.
    public static func writeBaseline(rootURL: URL? = nil) throws -> Activation? {
        let root = try rootURL ?? readRoot()
        return (try? activation(rootURL: root)) ?? nil
    }

    public static func snapshot(rootURL: URL? = nil, selectedOnly: Bool = false) throws -> Snapshot? {
        let root = try rootURL ?? readRoot()
        guard let activation = try activation(rootURL: root) else { return nil }
        if selectedOnly && !activation.recipeEnabled { return nil }
        if activation.generation.isEmpty && !activation.recipeEnabled { return nil }
        return try snapshot(for: activation, root: root)
    }

    static func snapshot(for activation: Activation, root: URL) throws -> Snapshot {
        var activation = activation
        guard !activation.generation.isEmpty,
            activation.generation.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else {
            throw StoreError(message: String(localized: "输入方案版本标识格式无效"))
        }
        let version = root.appendingPathComponent("versions/\(activation.generation)")
        let resources = version.appendingPathComponent("resources")
        let build = resources.appendingPathComponent("build")
        activation.schemas = try resolvedSchemas(activation.schemas, build: build)
        return Snapshot(activation: activation, resources: resources, build: build)
    }

    /// Without schema metadata only the deployed default is authoritative, never layout aliases
    /// or the set of compiled dependency files. Nonempty publication metadata stays restrictive.
    static func resolvedSchemas(_ metadata: [KeyboardSchemaDescriptor]?, build: URL) throws
        -> [KeyboardSchemaDescriptor]
    {
        // Private Config object: no global config_open, engine startup, deployment or select.
        let yaml = try String(contentsOf: build.appendingPathComponent("default.yaml"), encoding: .utf8)
        guard let api = rime_get_api() else { throw StoreError(message: String(localized: "Rime 配置接口不可用")) }
        var config = RimeConfig()
        defer { _ = api.pointee.config_close(&config) }
        guard yaml.withCString({ api.pointee.config_load_string(&config, $0) }) != 0 else {
            throw StoreError(message: String(localized: "方案默认配置文件（default.yaml）解析失败，请重新安装输入方案"))
        }
        let count = Int(api.pointee.config_list_size(&config, "schema_list"))
        let ids: [String] = (0..<count).compactMap { index in
            "schema_list/@\(index)/schema".withCString { key in
                api.pointee.config_get_cstring(&config, key).map { String(cString: $0) }
            }
        }
        guard !ids.isEmpty, ids.count == count, Set(ids).count == ids.count,
            ids.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("..") })
        else {
            throw StoreError(message: String(localized: "方案默认配置中缺少有效的方案列表，请重新安装输入方案"))
        }
        let result = (metadata?.isEmpty == false) ? metadata! : ids.map { .init(id: $0, name: $0) }
        guard Set(result.map(\.id)).count == result.count,
            result.allSatisfy({ ids.contains($0.id) })
        else {
            throw StoreError(message: String(localized: "已添加的键盘与方案默认配置不一致，请重新选择"))
        }
        return result
    }

    static func deployedSchemas(build: URL) throws -> [KeyboardSchemaDescriptor] {
        let enabled = try resolvedSchemas(nil, build: build)
        guard let api = rime_get_api() else { throw StoreError(message: String(localized: "Rime 配置接口不可用")) }
        // Written by the host at deployment; a build from before profiles has none and keeps the family rule.
        let profiles =
            (try? Data(contentsOf: build.appendingPathComponent(SchemaKeyProfile.fileName)))
            .flatMap(SchemaKeyProfile.decode) ?? [:]
        return try enabled.map { entry in
            let yaml = try String(contentsOf: build.appendingPathComponent(entry.id + ".schema.yaml"), encoding: .utf8)
            var config = RimeConfig()
            defer { _ = api.pointee.config_close(&config) }
            guard yaml.withCString({ api.pointee.config_load_string(&config, $0) }) != 0 else {
                throw StoreError(message: String(localized: "无法读取输入方案：\(entry.id)"))
            }
            let name = api.pointee.config_get_cstring(&config, "schema/name").map { String(cString: $0) } ?? entry.id
            let alphabet = api.pointee.config_get_cstring(&config, "speller/alphabet").map { String(cString: $0) } ?? ""
            return KeyboardSchemaDescriptor(
                id: entry.id, name: name, alphabet: alphabet, profile: profiles[entry.id])
        }
    }
}

// MARK: - Choice kept without Full Access

extension KeyboardRecipeStore {
    /// A keyboard picked in the keyboard while the App Group is read-only (no Full Access). It lives
    /// in the extension's own defaults, which it can always write, and applies only while the shared
    /// record still says what it said when the pick was made: a choice made in the host app since
    /// then wins, and this one is dropped.
    struct PrivateSelection: Codable, Equatable, Sendable {
        var baseGeneration: String
        var baseSchemaID: String?
        var baseLayout: KeyboardLayoutKind?
        var baseBoard: String?
        var schemaID: String
        var layout: KeyboardLayoutKind
        var board: String?
    }

    static let privateSelectionKey = "keyboard.privateSelection.v1"

    /// Keeps a pick the shared record cannot take. False when there is no published record to base it on.
    @discardableResult
    public static func savePrivateSelection(
        schemaID: String, layout: KeyboardLayoutKind, board: String?,
        defaults: UserDefaults = .standard, rootURL: URL? = nil
    ) -> Bool {
        let read = applyingPrivatePackageSwitch(readSelection(rootURL: rootURL), defaults: defaults)
        guard read.readError == nil, let data = read.data,
            let base = try? JSONDecoder().decode(Activation.self, from: data), base.recipeEnabled
        else { return false }
        let record = PrivateSelection(
            baseGeneration: base.generation, baseSchemaID: base.selectedSchemaID,
            baseLayout: base.selectedLayout, baseBoard: base.selectedBoard,
            schemaID: schemaID, layout: layout, board: board)
        guard let encoded = try? JSONEncoder().encode(record) else { return false }
        defaults.set(encoded, forKey: privateSelectionKey)
        return true
    }

    /// Forgets the kept pick: the shared record now holds the user's choice.
    public static func clearPrivateSelection(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: privateSelectionKey)
    }

    /// [read] with the kept pick applied while the shared record is still the one it was made on,
    /// and the pick is still a published keyboard there. Otherwise the kept pick is dropped and
    /// [read] is returned as it is.
    public static func applyingPrivateSelection(
        _ read: SelectionRead, defaults: UserDefaults = .standard
    ) -> SelectionRead {
        guard let stored = defaults.data(forKey: privateSelectionKey) else { return read }
        guard read.readError == nil, let data = read.data,
            var activation = try? JSONDecoder().decode(Activation.self, from: data),
            let record = try? JSONDecoder().decode(PrivateSelection.self, from: stored)
        else { return read }
        let unchanged =
            activation.recipeEnabled && activation.generation == record.baseGeneration
            && activation.selectedSchemaID == record.baseSchemaID
            && activation.selectedLayout == record.baseLayout && activation.selectedBoard == record.baseBoard
        let pick = PublishedKeyboard(schemaID: record.schemaID, layout: record.layout, board: record.board)
        let published =
            activation.requiredSchemaIDs.contains(record.schemaID)
            && (activation.publishedKeyboards == nil || activation.keyboards.contains(pick))
        guard unchanged, published else {
            clearPrivateSelection(defaults: defaults)
            return read
        }
        activation.selectedSchemaID = record.schemaID
        activation.selectedLayout = record.layout
        activation.selectedBoard = record.board
        guard let rewritten = try? canonicalJSONEncoder().encode(activation) else { return read }
        return SelectionRead(root: read.root, data: rewritten, readError: nil)
    }
}

// MARK: - Package switch kept without Full Access

extension KeyboardRecipeStore {
    /// A switch to another package made in the keyboard while the App Group is read-only. The host
    /// app already keeps a compiled generation for every package with added keyboards
    /// (`keptGenerations`), so nothing is copied: the keyboard only remembers which kept package and
    /// keyboard to read, and applies the same switch `activateKeptPackage` would write. Learning
    /// stays where it always is, in the extension's per-package user directory.
    ///
    /// Like `PrivateSelection` it applies only while the shared record is the one it was made on.
    /// Once Full Access is on, `promotePrivateChoices` writes it into the shared record.
    struct PrivatePackageSwitch: Codable, Equatable, Sendable {
        var baseGeneration: String
        var baseEnabled: Bool
        var baseSchemaID: String?
        var baseLayout: KeyboardLayoutKind?
        var baseBoard: String?
        var rosterKey: String
        var keyboard: PublishedKeyboard

        func isBased(on activation: Activation) -> Bool {
            activation.generation == baseGeneration && activation.recipeEnabled == baseEnabled
                && activation.selectedSchemaID == baseSchemaID && activation.selectedLayout == baseLayout
                && activation.selectedBoard == baseBoard
        }
    }

    static let privatePackageSwitchKey = "keyboard.privatePackageSwitch.v1"

    /// Keeps a switch to `keyboard` of the kept package `rosterKey` that the shared record cannot
    /// take. Switching back to the package the shared record names drops the switch instead. False
    /// when the switch is not possible (the package is no longer kept, or the keyboard was removed).
    @discardableResult
    public static func savePrivatePackageSwitch(
        rosterKey: String, keyboard: PublishedKeyboard,
        defaults: UserDefaults = .standard, rootURL: URL? = nil
    ) -> Bool {
        let read = readSelection(rootURL: rootURL)
        guard read.readError == nil, let data = read.data, let root = read.root,
            let shared = try? JSONDecoder().decode(Activation.self, from: data)
        else { return false }
        if rosterKey == shared.rosterKey, shared.recipeEnabled {
            clearPrivatePackageSwitch(defaults: defaults)
            if shared.selectedSchemaID == keyboard.schemaID && shared.selectedLayout == keyboard.layout
                && shared.selectedBoard == keyboard.board
            {
                clearPrivateSelection(defaults: defaults)
                return true
            }
            return savePrivateSelection(
                schemaID: keyboard.schemaID, layout: keyboard.layout, board: keyboard.board,
                defaults: defaults, rootURL: rootURL)
        }
        guard (try? keptPackageActivation(from: shared, rosterKey: rosterKey, keyboard: keyboard, root: root)) != nil
        else { return false }
        let record = PrivatePackageSwitch(
            baseGeneration: shared.generation, baseEnabled: shared.recipeEnabled,
            baseSchemaID: shared.selectedSchemaID, baseLayout: shared.selectedLayout,
            baseBoard: shared.selectedBoard, rosterKey: rosterKey, keyboard: keyboard)
        guard let encoded = try? JSONEncoder().encode(record) else { return false }
        defaults.set(encoded, forKey: privatePackageSwitchKey)
        // A pick inside the package being left no longer means anything.
        clearPrivateSelection(defaults: defaults)
        return true
    }

    public static func clearPrivatePackageSwitch(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: privatePackageSwitchKey)
    }

    /// [read] with the kept switch applied while the shared record is still the one it was made on
    /// and the target is still kept. Otherwise the switch is dropped and [read] returned as it is.
    public static func applyingPrivatePackageSwitch(
        _ read: SelectionRead, defaults: UserDefaults = .standard
    ) -> SelectionRead {
        guard let stored = defaults.data(forKey: privatePackageSwitchKey) else { return read }
        guard read.readError == nil, let data = read.data, let root = read.root,
            let shared = try? JSONDecoder().decode(Activation.self, from: data),
            let record = try? JSONDecoder().decode(PrivatePackageSwitch.self, from: stored)
        else { return read }
        guard record.isBased(on: shared),
            let next = try? keptPackageActivation(
                from: shared, rosterKey: record.rosterKey, keyboard: record.keyboard, root: root),
            let rewritten = try? canonicalJSONEncoder().encode(next)
        else {
            clearPrivatePackageSwitch(defaults: defaults)
            return read
        }
        return SelectionRead(root: read.root, data: rewritten, readError: nil)
    }

    /// The shared record as this keyboard sees it: a package switch, then a keyboard pick, kept
    /// without Full Access applied over it. In the host app nothing is kept, so it is the shared record.
    public static func applyingPrivateChoices(
        _ read: SelectionRead, defaults: UserDefaults = .standard
    ) -> SelectionRead {
        applyingPrivateSelection(applyingPrivatePackageSwitch(read, defaults: defaults), defaults: defaults)
    }

    /// `activation()` as this keyboard sees it (see `applyingPrivateChoices`).
    public static func effectiveActivation(
        defaults: UserDefaults = .standard, rootURL: URL? = nil
    ) throws -> Activation? {
        let read = applyingPrivateChoices(readSelection(rootURL: rootURL), defaults: defaults)
        if let error = read.readError { throw StoreError(message: error) }
        guard let data = read.data else { return nil }
        return try JSONDecoder().decode(Activation.self, from: data)
    }

    /// With Full Access back, writes what was kept without it into the shared record, so the host
    /// app shows the same choice, then forgets it. A kept choice the shared record moved past is
    /// dropped by the reads above; nothing here overrides a newer host choice.
    public static func promotePrivateChoices(defaults: UserDefaults = .standard, rootURL: URL? = nil) {
        guard canWriteSharedContainer else { return }
        if let stored = defaults.data(forKey: privatePackageSwitchKey),
            let record = try? JSONDecoder().decode(PrivatePackageSwitch.self, from: stored)
        {
            try? activateKeptPackage(
                rosterKey: record.rosterKey, keyboard: record.keyboard,
                expectedGeneration: record.baseGeneration, rootURL: rootURL)
            clearPrivatePackageSwitch(defaults: defaults)
        }
        let read = applyingPrivateSelection(readSelection(rootURL: rootURL), defaults: defaults)
        guard defaults.data(forKey: privateSelectionKey) != nil,
            let data = read.data, let picked = try? JSONDecoder().decode(Activation.self, from: data),
            let schemaID = picked.selectedSchemaID, let layout = picked.selectedLayout
        else { return }
        if (try? saveSelection(
            schemaID: schemaID, layout: layout, board: picked.selectedBoard,
            runtimeIdentity: .published, rootURL: rootURL)) == .saved
        {
            clearPrivateSelection(defaults: defaults)
        }
    }
}

/// Sorted keys keep the encoded bytes of dictionary-bearing records identical across processes.
func canonicalJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}
