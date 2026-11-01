import CandidateKit
import Darwin
import Foundation
import SkinKit

/// The unified "appearance project": one user-facing unit = keyboard skin + candidate area layout behavior.
///
/// Identity rule (single, verifiable):
///     document.id == skin.id == candidateBar.id
/// Any mismatch is a mixed-generation document and is rejected on decode/read. A runtime snapshot
/// therefore always comes from one commit; "new skin + old candidate bar" cannot exist.
///
/// Content boundary:
///   - `skin` still owns all colors and fonts (including `typography.candidateSize`).
///   - `candidateBar` only describes candidate area layout behavior (composition row visibility,
///     collapsed strip height/padding, expanded layout, control placement); it carries no colors
///     and cannot configure fake candidates.
public struct AppearanceDocument: Codable, Equatable, Identifiable, Sendable {
    public static let formatVersionValue = 1
    public static let systemDefaultID = "system-default"
    public static let fileExtension = ".songyanappearance.json"

    public var formatVersion = AppearanceDocument.formatVersionValue
    public var id: String
    public var name: String
    public var author: String?
    /// Light/dark/follow-system is committed together with the skin and belongs to the same appearance identity.
    public var appearance: SkinAppearance
    public var skin: SkinDefinition
    public var candidateBar: CandidateBarDefinition

    /// Construction enforces identity lockstep: the given skin and candidate area are re-attached to
    /// this project's identity (only id/name change), so a mixed-generation document cannot be built.
    public init(
        id: String, name: String,
        appearance: SkinAppearance = .system,
        skin: SkinDefinition? = nil,
        candidateBar: CandidateBarDefinition? = nil
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.skin = Self.reidentified(skin ?? SkinDefinition(id: id, name: name), id: id, name: name)
        self.candidateBar = Self.reidentified(
            candidateBar ?? CandidateBarDefinition(id: id, name: name),
            id: id, name: name)
    }

    /// Built-in system default appearance: system default skin + system default candidate layout (read-only; duplicate to edit).
    public static let systemDefault = AppearanceDocument(
        id: systemDefaultID, name: "系统默认",
        skin: .systemDefault, candidateBar: .systemDefault)

    public var isSystemDefault: Bool { id == Self.systemDefaultID }

    // MARK: - Identity consistency

    /// Whether the three identities agree (skin, candidate bar, project).
    public var identityIsConsistent: Bool {
        id == skin.id && id == candidateBar.id
    }

    /// Stable identity string for logs/tests (contains no user-visible text).
    public var identityDescription: String {
        "\(id)|\(skin.id)|\(candidateBar.id)"
    }

    // MARK: - Normalize / duplicate

    /// Normalizes: the name is unified to the project name (one user-visible name per appearance),
    /// the skin is normalized (resolved colors are filled and materialized), the candidate bar is re-attached to the same identity.
    public func normalized() -> AppearanceDocument {
        var result = self
        result.formatVersion = Self.formatVersionValue
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.skin = Self.reidentified(skin, id: id, name: result.name).normalized()
        result.candidateBar = Self.reidentified(candidateBar, id: id, name: result.name)
        return result
    }

    /// Duplicates: one new identity is applied to project, skin and candidate bar at once; the name gets a "副本" suffix.
    public func copy() -> AppearanceDocument {
        let newID = UUID().uuidString.lowercased()
        var result = normalized()
        result.id = newID
        result.name = name + " 副本"
        result.skin = Self.reidentified(skin, id: newID, name: result.name).normalized()
        result.candidateBar = Self.reidentified(candidateBar, id: newID, name: result.name)
        return result
    }

    /// Re-attaches the skin to a new identity (only id/name change; content as-is).
    public static func reidentified(_ skin: SkinDefinition, id: String, name: String) -> SkinDefinition {
        var copy = skin
        copy.id = id
        copy.name = name
        return copy
    }

    /// Re-attaches the candidate-area config to a new identity (only id/name change; layout parameters as-is).
    public static func reidentified(_ bar: CandidateBarDefinition, id: String, name: String) -> CandidateBarDefinition {
        var copy = bar
        copy.id = id
        copy.name = name
        return copy
    }

    /// Replaces this appearance's candidate-area layout (skin unchanged; the three identities stay in lockstep).
    public func replacing(candidateBar bar: CandidateBarDefinition) -> AppearanceDocument {
        AppearanceDocument(id: id, name: name, appearance: appearance, skin: skin, candidateBar: bar)
    }

    /// Replaces this appearance's skin (candidate layout unchanged; the three identities stay in lockstep).
    public func replacing(skin: SkinDefinition) -> AppearanceDocument {
        AppearanceDocument(id: id, name: name, appearance: appearance, skin: skin, candidateBar: candidateBar)
    }

    // MARK: - Validation

    public func validate() throws {
        func require(_ test: Bool, _ path: String) throws {
            if !test { throw AppearanceError("\(path): 值无效") }
        }
        try require(formatVersion == Self.formatVersionValue, "$.formatVersion")
        let charset = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")
        try require(!id.isEmpty && id.unicodeScalars.allSatisfy(charset.contains), "$.id")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "$.name")
        try skin.validate()
        try candidateBar.validate()
        // Composite identity: skin/candidate-bar generation mixing is not allowed.
        try require(id == skin.id, "$.skin.id 必须等于 $.id（皮肤与外观项目标识必须一致）")
        try require(id == candidateBar.id, "$.candidateBar.id 必须等于 $.id（候选栏归属该外观项目）")
    }

    // MARK: - Coding (strict fields + default filling, same discipline as SkinKit/CandidateKit)

    static let topLevelFields: Set<String> = [
        "formatVersion", "id", "name", "author", "appearance", "skin", "candidateBar",
    ]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024 else { throw AppearanceError("$: JSON 超过 256KB") }
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppearanceError("$: 需要对象")
        }
        guard source["formatVersion"] as? Int == formatVersionValue else {
            throw AppearanceError("$.formatVersion: 只支持 \(formatVersionValue)")
        }
        // Known fields are kept, unknown fields rejected; nested content is validated by each package's strict decoding.
        var payload: [String: Any] = [:]
        for (key, value) in source {
            guard topLevelFields.contains(key) else { throw AppearanceError("$.\(key): 未知字段") }
            payload[key] = value
        }
        guard let id = payload["id"] as? String, !id.isEmpty else { throw AppearanceError("$.id: 缺少或为空") }
        guard let name = payload["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AppearanceError("$.name: 缺少或为空")
        }
        guard let skinObject = payload["skin"], let barObject = payload["candidateBar"] else {
            throw AppearanceError("$: 外观项目必须同时包含 skin 与 candidateBar")
        }
        // Skin and candidate area each go through their own package's strict decoding (unknown fields, invalid values, wrong versions are rejected).
        let skin = try SkinDefinition.decode(try JSONSerialization.data(withJSONObject: skinObject))
        let bar = try CandidateBarDefinition.decode(try JSONSerialization.data(withJSONObject: barObject))
        // Mixed generations must be rejected: skin/candidate-area identities in the file must match the project's.
        // (The programmatic `init` re-attaches identities, but persisted content must not be inconsistent.)
        guard skin.id == id else {
            throw AppearanceError("$.skin.id: 与 $.id 不一致（皮肤与外观项目不匹配）")
        }
        guard bar.id == id else {
            throw AppearanceError("$.candidateBar.id: 与 $.id 不一致（候选栏与外观项目不匹配）")
        }
        var document = AppearanceDocument(id: id, name: name, skin: skin, candidateBar: bar)
        if let author = payload["author"] {
            guard let author = author as? String else { throw AppearanceError("$.author: 需要字符串") }
            document.author = author
        }
        if let appearance = payload["appearance"] {
            guard let raw = appearance as? String, let parsed = SkinAppearance(rawValue: raw) else {
                throw AppearanceError("$.appearance: 需要 system/light/dark")
            }
            document.appearance = parsed
        }
        try document.validate()
        return document.normalized()
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized())
        guard data.count <= 256 * 1024 else { throw AppearanceError("$: JSON 超过 256KB") }
        return data
    }

    // MARK: - Import of user-supplied files

    /// Imports one file as an appearance project, handling three input kinds deterministically:
    ///   1. appearance project JSON (this package's format);
    ///   2. standalone skin JSON (`*.songyanskin.json`) -> wrapped with the current system-default candidate layout;
    ///   3. standalone candidate-area JSON (`*.songyancand.json`) -> wrapped with the system-default skin.
    /// Legacy `system-default` files are copied to a new identity to avoid colliding with the read-only built-in.
    public static func decodeImported(contentsOf url: URL) throws -> AppearanceDocument {
        try decodeImported(
            readData(
                from: url, maximumBytes: 256 * 1024,
                oversizeMessage: "$: JSON 超过 256KB"))
    }

    /// Reads an untrusted user-supplied file: it must be a regular file within the size limit.
    static func readData(from url: URL, maximumBytes: Int, oversizeMessage: String) throws -> Data {
        guard url.isFileURL else { throw AppearanceError("需要本地普通文件") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AppearanceError("需要普通文件") }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw AppearanceError(oversizeMessage) }
        return try Data(contentsOf: url)
    }

    public static func decodeImported(_ data: Data) throws -> AppearanceDocument {
        guard data.count <= 256 * 1024 else { throw AppearanceError("$: JSON 超过 256KB") }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any]
        else {
            throw AppearanceError("$: 需要对象")
        }
        // A snapshot file (selection + content) is not an importable config: give clear guidance instead of a vague schema error.
        let snapshotKeys: Set<String> = ["selectedSkinID", "selectedBarID", "selectedID"]
        if !snapshotKeys.isDisjoint(with: object.keys) {
            throw AppearanceError("$: 这是快照文件（选择与内容），请分别导入皮肤、候选栏或外观项目文件。")
        }
        if object["skin"] != nil || object["candidateBar"] != nil {
            return try decode(data)
        }
        let skinKeys: Set<String> = ["variants", "typography", "keycap", "spacing"]
        let barKeys: Set<String> = ["compositionRow", "collapsed", "expanded", "controls"]
        if !skinKeys.isDisjoint(with: object.keys) {
            var skin = try SkinDefinition.decode(data)
            if skin.id == SkinDefinition.systemDefault.id { skin = skin.copy() }
            return try decode(
                AppearanceDocument(
                    id: skin.id, name: skin.name,
                    skin: skin, candidateBar: .systemDefault
                ).encoded())
        }
        if !barKeys.isDisjoint(with: object.keys) {
            var bar = try CandidateBarDefinition.decode(data)
            if bar.id == CandidateBarDefinition.systemDefaultID { bar = bar.copy() }
            return try decode(
                AppearanceDocument(
                    id: bar.id, name: bar.name,
                    skin: .systemDefault, candidateBar: bar
                ).encoded())
        }
        throw AppearanceError("$: 无法识别为皮肤、候选栏或外观项目文件。")
    }
}

/// Appearance project errors (same readable "path: message" convention as the two underlying packages).
public struct AppearanceError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Built-in preset appearances (read-only; duplicate to edit)

extension AppearanceDocument {
    /// Built-in appearances besides the system default. Identities are fixed and not deletable; users "duplicate and edit" to get their own.
    public static let builtinPresets: [AppearanceDocument] = [
        preset(
            id: "builtin-songyan", name: "松烟墨韵", appearance: .system,
            light: [
                "panel": "#E6E8E8", "key": "#FCFDFE", "control": "#D4DAD9", "accent": "#2A593F",
                "accentText": "#FFFFFF", "text": "#202427", "secondaryText": "#535C5F",
                "selected": "#D3E2E3", "pressed": "#C8D2D4", "border": "#D9DFDC",
            ],
            dark: [
                "panel": "#1F2224", "key": "#3A3D41", "control": "#2E3135", "accent": "#8FD7AA",
                "accentText": "#003820", "text": "#EDEFEE", "secondaryText": "#ADB5B7",
                "selected": "#284043", "pressed": "#515960", "border": "#262A2A",
            ],
            // Dark keys sit close to the panel; the stroke keeps them apart.
            borderWidth: 1),
        preset(
            id: "builtin-ink", name: "墨夜", appearance: .system,
            light: [
                "panel": "#E2E4E9", "key": "#FCFDFE", "control": "#CED2DA", "accent": "#2B2D33",
                "accentText": "#FFFFFF", "text": "#1D222C", "secondaryText": "#4E5763",
                "selected": "#CFD7E3", "pressed": "#ADB6C2",
            ],
            dark: [
                "panel": "#202226", "key": "#3C3F46", "control": "#2F3238", "accent": "#3A6EA5",
                "accentText": "#FFFFFF", "text": "#F3F4F6", "secondaryText": "#B4BAC5",
                "selected": "#3A638F", "pressed": "#545A66",
            ]),
        preset(
            id: "builtin-bamboo", name: "青竹", appearance: .system,
            light: [
                "panel": "#DEE5E4", "key": "#FAFCFC", "control": "#C7D3D0", "accent": "#2E7D5B",
                "accentText": "#FFFFFF", "text": "#22292B", "secondaryText": "#4E5A5D",
                "selected": "#C4DCD9", "pressed": "#B8CAC8",
            ],
            dark: [
                "panel": "#222628", "key": "#3F4648", "control": "#32383A", "accent": "#34805E",
                "accentText": "#FFFFFF", "text": "#F2F5F4", "secondaryText": "#B7C3C4",
                "selected": "#345A58", "pressed": "#556166",
            ]),
        preset(
            id: "builtin-paper", name: "暖纸", appearance: .system,
            light: [
                "panel": "#E6E4E0", "key": "#FCFCF9", "control": "#D4D0CC", "accent": "#AA5F28",
                "accentText": "#FFFFFF", "text": "#292828", "secondaryText": "#5A5A59",
                "selected": "#DED6D0", "pressed": "#CAC8C5",
            ],
            dark: [
                "panel": "#262628", "key": "#464648", "control": "#37373A", "accent": "#A66331",
                "accentText": "#FFFFFF", "text": "#F5F3F0", "secondaryText": "#C2C0BF",
                "selected": "#574E49", "pressed": "#5B5E64",
            ]),
        preset(
            id: "builtin-galaxy", name: "星河", appearance: .system,
            light: [
                "panel": "#DEE3EA", "key": "#FCFDFE", "control": "#C8D2DE", "accent": "#1A56DB",
                "accentText": "#FFFFFF", "text": "#1C2532", "secondaryText": "#4C586A",
                "selected": "#C9D9ED", "pressed": "#BAC8DA",
            ],
            dark: [
                "panel": "#1F222A", "key": "#393E47", "control": "#2D323C", "accent": "#316CCC",
                "accentText": "#FFFFFF", "text": "#F4F5F7", "secondaryText": "#ABB6C7",
                "selected": "#30496D", "pressed": "#4F5A6B",
            ]),
        preset(
            id: "builtin-twilight", name: "薄暮", appearance: .system,
            light: [
                "panel": "#E4E2EA", "key": "#FCFDFE", "control": "#D0CEDB", "accent": "#7E3AF2",
                "accentText": "#FFFFFF", "text": "#252332", "secondaryText": "#585768",
                "selected": "#D6D7EA", "pressed": "#C2C2D3",
            ],
            dark: [
                "panel": "#22222A", "key": "#3D3C48", "control": "#30303B", "accent": "#954BDA",
                "accentText": "#FFFFFF", "text": "#F4F2F8", "secondaryText": "#B7B6C7",
                "selected": "#464468", "pressed": "#555868",
            ]),
    ]

    public static let builtinPresetIDs: Set<String> = Set(builtinPresets.map(\.id))

    /// Built-in appearances (system default + presets): read-only, not deletable.
    public var isBuiltin: Bool { isSystemDefault || Self.builtinPresetIDs.contains(id) }

    private static func preset(
        id: String, name: String, appearance: SkinAppearance,
        light: [String: String]?, dark: [String: String]?, borderWidth: Double = 0
    ) -> AppearanceDocument {
        var skin = SkinDefinition.systemDefault
        skin.id = id
        skin.name = name
        skin.keycap.borderWidth = borderWidth
        if let light { skin.variants.light?.colors = light }
        if let dark { skin.variants.dark?.colors = dark }
        return AppearanceDocument(
            id: id, name: name, appearance: appearance, skin: skin,
            candidateBar: .systemDefault
        ).normalized()
    }
}
