import Foundation

/// The presets shipped with the app.
///
/// The Xiaohe map is the display table the built-in 26-key shuangpin layout already carried. It
/// does not declare, derive or restrict what the engine accepts.
public enum ShuangpinHintPresets {
    /// Identity of the built-in preset. The default snapshot always contains it.
    public static let builtinID = "xiaohe-26"

    public static let builtinXiaohe = ShuangpinHintPreset(
        id: builtinID,
        name: "小鹤双拼提示",
        hints: [
            "q": "iu", "w": "ei", "r": "uan", "t": "ue", "y": "un",
            "u": "sh", "i": "ch", "o": "uo", "p": "ie", "s": "ong/iong",
            "d": "ai", "f": "en", "g": "eng", "h": "ang", "j": "an",
            "k": "ing/uai", "l": "iang/uang", "z": "ou", "x": "ia/ua",
            "c": "ao", "v": "zh/ui", "b": "in", "n": "iao", "m": "ian",
        ])

    public static let all: [ShuangpinHintPreset] = [builtinXiaohe]
}

/// Everything the keyboard needs in one atomic read: the switch, the selection and the preset
/// contents. Committing them together means the extension can never read a selection whose preset
/// is missing.
public struct ShuangpinHintSnapshot: Codable, Equatable, Sendable {
    /// Format version of the stored snapshot.
    public static let currentVersion = 1
    /// Bound on one stored file; the host UI keeps fewer in practice.
    public static let maximumPresets = 64

    public var version: Int
    /// Off by default: the user opts in explicitly.
    public var enabled: Bool
    public var selectedPresetID: String
    public var presets: [ShuangpinHintPreset]

    public init(
        enabled: Bool = false, selectedPresetID: String = ShuangpinHintPresets.builtinID,
        presets: [ShuangpinHintPreset] = ShuangpinHintPresets.all,
        version: Int = currentVersion
    ) {
        self.version = version
        self.enabled = enabled
        self.selectedPresetID = selectedPresetID
        self.presets = presets
    }

    /// The state used when nothing is stored yet: hints off, built-in preset selected.
    public static var disabled: ShuangpinHintSnapshot { ShuangpinHintSnapshot() }

    /// The preset the keyboard may draw, or nil when hints are off or the selection is unusable.
    /// This is the only gate the renderer needs: nil means "draw nothing".
    public var activePreset: ShuangpinHintPreset? {
        guard enabled else { return nil }
        return preset(id: selectedPresetID)
    }

    public func preset(id: String) -> ShuangpinHintPreset? {
        presets.first { $0.id == id }
    }

    public var userPresets: [ShuangpinHintPreset] {
        presets.filter { $0.id != ShuangpinHintPresets.builtinID }
    }

    public func isBuiltin(_ preset: ShuangpinHintPreset) -> Bool {
        preset.id == ShuangpinHintPresets.builtinID
    }

    public var selectedPresetName: String {
        preset(id: selectedPresetID)?.name ?? selectedPresetID
    }

    /// Used when building a complete list (a new snapshot, or an explicit restore). Loading never
    /// calls this: a stored file is either consistent or refused.
    public func ensuringBuiltinPreset() -> Self {
        guard preset(id: ShuangpinHintPresets.builtinID) == nil else { return self }
        var value = self
        value.presets.insert(ShuangpinHintPresets.builtinXiaohe, at: 0)
        return value
    }

    /// Strict: an inconsistent snapshot is refused, never silently repaired. Re-pointing a broken
    /// selection at the built-in preset would show hints the user never chose.
    public func validate() throws {
        try check(
            version == Self.currentVersion,
            String(localized: "shinpin.field.version", bundle: .module),
            String(
                format: String(localized: "shinpin.reason.onlyVersion", bundle: .module),
                String(Self.currentVersion)))
        try check(
            presets.count <= Self.maximumPresets,
            String(localized: "shinpin.field.presetCount", bundle: .module),
            String(
                format: String(localized: "shinpin.reason.moreThanMaximum", bundle: .module),
                String(Self.maximumPresets)))
        try check(
            Set(presets.map(\.id)).count == presets.count,
            String(localized: "shinpin.field.presetList", bundle: .module),
            String(localized: "shinpin.reason.idsUnique", bundle: .module))
        try check(
            !selectedPresetID.isEmpty,
            String(localized: "shinpin.field.currentPreset", bundle: .module),
            String(localized: "shinpin.reason.selectPreset", bundle: .module))
        try check(
            preset(id: selectedPresetID) != nil,
            String(localized: "shinpin.field.currentPreset", bundle: .module),
            String(
                format: String(localized: "shinpin.reason.presetNotFound", bundle: .module),
                selectedPresetID))
        for preset in presets { try preset.validate() }
    }

    private func check(_ condition: Bool, _ field: String, _ reason: String) throws {
        guard condition else {
            throw ShuangpinHintError(
                String(
                    format: String(localized: "shinpin.error.settingsUnusable", bundle: .module),
                    field, reason))
        }
    }
}

/// Host writes; the keyboard extension only reads.
///
/// A missing file is the default off state. A damaged file throws, so the caller keeps the last
/// valid value and can offer an explicit reset instead of overwriting it.
public struct ShuangpinHintStore: Sendable {
    /// Directory name under the App Group container; also shown by the host UI.
    public static let directoryName = "ShuangpinHints"
    public static let catalogFileName = "hints.json"

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var catalogURL: URL { directory.appendingPathComponent(Self.catalogFileName) }

    /// Reads the snapshot. A missing file is the default off state, not an error; an unreadable or
    /// invalid file throws so the caller keeps the last valid snapshot and says so.
    public func load() throws -> ShuangpinHintSnapshot {
        let data: Data
        do {
            data = try LayoutResourceBudget.read(catalogURL, maximumBytes: ShuangpinHintDocument.maximumBytes)
        } catch let error as POSIXError where error.code == .ENOENT {
            return .disabled
        } catch let error as LayoutError {
            throw ShuangpinHintError(Self.friendly(error))
        }
        return try Self.decodeSnapshot(data)
    }

    /// Validates and persists the whole snapshot atomically. Nothing is written when validation
    /// fails. The caller runs this off the main thread.
    public func save(_ snapshot: ShuangpinHintSnapshot) throws {
        let data = try Self.encodeSnapshot(snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: catalogURL, options: .atomic)
    }

    /// Reads a file the user picked with the same bounded descriptor read as the store's own file:
    /// a symbolic link or pipe is refused, and the byte count is re-checked while reading. The caller
    /// keeps security-scoped access alive for the whole call.
    public static func readImportedFile(at url: URL) throws -> Data {
        do {
            return try LayoutResourceBudget.read(url, maximumBytes: ShuangpinHintDocument.maximumBytes)
        } catch let error as LayoutError {
            throw ShuangpinHintError(friendly(error))
        } catch {
            throw ShuangpinHintError(
                String(localized: "shinpin.error.fileUnopenable", bundle: .module))
        }
    }

    // MARK: - Documents

    /// Strict decode: unknown fields, wrong versions, wrong JSON types and inconsistent selections
    /// are refused with the offending field named.
    public static func decodeSnapshot(_ data: Data) throws -> ShuangpinHintSnapshot {
        let settingsLabel = String(localized: "shinpin.field.settings", bundle: .module)
        try ShuangpinHintDocument.checkSize(data, settingsLabel)
        let root = try ShuangpinHintDocument.object(
            data, settingsLabel, String(localized: "shinpin.malformed.chooseSettings", bundle: .module))
        try ShuangpinHintDocument.rejectUnknownKeys(
            root, allowed: ["version", "enabled", "selectedPresetID", "presets"])
        let version =
            try ShuangpinHintDocument.int(
                root["version"], String(localized: "shinpin.field.version", bundle: .module),
                key: "version")
            ?? ShuangpinHintSnapshot.currentVersion
        let enabled =
            try ShuangpinHintDocument.bool(
                root["enabled"], String(localized: "shinpin.field.enabled", bundle: .module),
                key: "enabled") ?? false
        let selected =
            try ShuangpinHintDocument.string(
                root["selectedPresetID"],
                String(localized: "shinpin.field.currentPreset", bundle: .module),
                key: "selectedPresetID", required: true) ?? ""
        var presets: [ShuangpinHintPreset] = []
        if let raw = root["presets"] {
            let presetList = String(localized: "shinpin.field.presetList", bundle: .module)
            guard let list = raw as? [Any] else {
                throw ShuangpinHintError(
                    String(
                        format: String(localized: "shinpin.error.settingsUnusable", bundle: .module),
                        presetList,
                        String(localized: "shinpin.reason.presetListNeeded", bundle: .module)))
            }
            guard list.count <= ShuangpinHintSnapshot.maximumPresets else {
                throw ShuangpinHintError(
                    String(
                        format: String(localized: "shinpin.error.settingsUnusable", bundle: .module),
                        presetList,
                        String(
                            format: String(
                                localized: "shinpin.reason.presetListMaximum", bundle: .module),
                            String(ShuangpinHintSnapshot.maximumPresets))))
            }
            for element in list {
                guard let object = element as? [String: Any] else {
                    throw ShuangpinHintError(
                        String(
                            format: String(
                                localized: "shinpin.error.settingsUnusable", bundle: .module),
                            presetList,
                            String(
                                localized: "shinpin.reason.presetListEntries", bundle: .module)))
                }
                presets.append(try ShuangpinHintPreset.decode(JSONSerialization.data(withJSONObject: object)))
            }
        }
        let snapshot = ShuangpinHintSnapshot(
            enabled: enabled, selectedPresetID: selected,
            presets: presets, version: version)
        try snapshot.validate()
        return snapshot
    }

    public static func encodeSnapshot(_ snapshot: ShuangpinHintSnapshot) throws -> Data {
        try snapshot.validate()
        let encoder = JSONEncoder.layoutKitPretty()
        let data = try encoder.encode(snapshot)
        try ShuangpinHintDocument.checkSize(
            data, String(localized: "shinpin.field.settings", bundle: .module))
        return data
    }

    /// One preset exported on its own, so it can be shared as a small readable file.
    public static func encodePreset(_ preset: ShuangpinHintPreset) throws -> Data {
        try preset.encoded()
    }

    /// Reads either a single preset file or a whole settings file. Enabled: the preset in use.
    /// Disabled: the first user preset, so importing a shared file yields something worth keeping.
    public static func decodePresetFile(_ data: Data) throws -> ShuangpinHintPreset {
        let fileLabel = String(localized: "shinpin.field.file", bundle: .module)
        try ShuangpinHintDocument.checkSize(data, fileLabel)
        let root = try ShuangpinHintDocument.object(
            data, fileLabel, String(localized: "shinpin.malformed.choosePreset", bundle: .module))
        if root["presets"] != nil {
            let snapshot = try decodeSnapshot(data)
            // A validated snapshot always contains its selected preset.
            guard
                let preset = snapshot.activePreset
                    ?? snapshot.userPresets.first
                    ?? snapshot.preset(id: snapshot.selectedPresetID)
            else {
                throw ShuangpinHintError(
                    String(localized: "shinpin.error.noUsablePreset", bundle: .module))
            }
            return preset
        }
        return try ShuangpinHintPreset.decode(data)
    }

    /// Maps an internal read failure to wording a user can act on.
    public static func friendly(_ error: LayoutError) -> String {
        switch error {
        case .invalid(let reason):
            return String(
                format: String(localized: "shinpin.error.settingsUnreadable", bundle: .module),
                reason)
        case .duplicateID(let id):
            return String(
                format: String(localized: "shinpin.error.settingsDuplicateID", bundle: .module),
                id)
        case .unknownID(let id):
            return String(
                format: String(localized: "shinpin.error.settingsUnknownID", bundle: .module),
                id)
        }
    }
}
