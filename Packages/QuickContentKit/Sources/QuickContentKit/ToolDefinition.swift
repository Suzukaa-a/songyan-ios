import Foundation

/// Limits shared by the model, the validator and the runner. The Android port uses the
/// same numbers so both platforms accept exactly the same files.
public enum ToolDefinitionLimits {
    public static let maximumSteps = 16
    public static let maximumIdentifierUTF8Bytes = 64
    public static let maximumNameCharacters = 64
    public static let maximumPatternUTF16CodeUnits = 256
    public static let maximumReplacementUTF16CodeUnits = 256
    public static let maximumMapEntries = 512
    public static let maximumMapValueCharacters = 16
    public static let maximumFileBytes = 64 * 1024
}

/// One OpenCC conversion that ships with the app. The raw values are the config names under
/// `Resources/EngineResources/opencc`; a config that is not bundled there must never be accepted,
/// because a tool can only run conversions the app carries.
public enum OpenCCToolConfig: String, CaseIterable, Sendable {
    case hk2s
    case hk2t
    case jp2t
    case s2hk
    case s2t
    case s2tw
    case s2twp
    case t2hk
    case t2jp
    case t2s
    case t2tw
    case tw2s
    case tw2sp
    case tw2t
}

/// One transformation step of a tool file, run in declaration order. The JSON spelling of the
/// type and its parameters is fixed by the format:
///
///     {"type":"opencc","config":"s2twp"}
///     {"type":"replace","pattern":"\\s+","replacement":" "}
///     {"type":"map","table":{"A":"B"}}
///     {"type":"case","mode":"upper"}        // upper, lower, capitalize
///     {"type":"width","mode":"toHalf"}      // toHalf, toFull
///     {"type":"template","pattern":"<{text}>"}
public enum ToolStep: Equatable, Sendable {
    /// `capitalize` uppercases the first character of every whitespace-separated word and leaves
    /// the rest unchanged.
    public enum CaseMode: String, CaseIterable, Sendable {
        case upper
        case lower
        case capitalize
    }

    /// `toHalf` maps full-width forms to ASCII, `toFull` maps ASCII to full-width forms.
    public enum WidthMode: String, CaseIterable, Sendable {
        case toHalf
        case toFull
    }

    case opencc(config: OpenCCToolConfig)
    case replace(pattern: String, replacement: String)
    case map(table: [String: String])
    case caseTransform(mode: CaseMode)
    case width(mode: WidthMode)
    case template(pattern: String)
}

/// A `.songyantool.json` tool definition (format version 1). Unknown fields are ignored; an
/// unknown step type, an unknown format version, an invalid regular expression and an unshipped
/// OpenCC config reject the whole file, because silently dropping a step would change what the
/// user asked the tool to do.
public struct ToolDefinition: Equatable, Sendable {
    public static let formatVersion = 1
    /// Name languages the file format defines. Unknown tags are ignored, not rejected.
    public static let nameLanguageTags = ["zh-Hans", "zh-Hant", "ja", "en"]
    /// The one template placeholder a `template` step must contain exactly once.
    public static let textPlaceholder = "{text}"

    public var formatVersion: Int
    public var id: String
    public var name: [String: String]
    public var steps: [ToolStep]

    public init(
        formatVersion: Int = ToolDefinition.formatVersion,
        id: String,
        name: [String: String],
        steps: [ToolStep]
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.steps = steps
    }

    /// Resolves the display name in the interface language. The lookup tries each preferred tag
    /// exactly (`ja-JP` does not match `ja`), then Simplified Chinese, then the first available
    /// tag in sorted tag order so the same file always shows the same name.
    public func displayName(preferredLanguageTags: [String]) -> String {
        for tag in preferredLanguageTags {
            if let value = name.first(where: { $0.key.caseInsensitiveCompare(tag) == .orderedSame })?.value {
                return value
            }
        }
        if let hans = name.first(where: { $0.key.caseInsensitiveCompare("zh-Hans") == .orderedSame })?.value {
            return hans
        }
        return name.keys.sorted().first.flatMap { name[$0] } ?? ""
    }

    /// Checks a definition that was built in memory, before it is saved or exported.
    public func validate() throws {
        guard formatVersion == ToolDefinition.formatVersion else {
            throw ToolDefinitionError(reason: .unsupportedFormatVersion(String(formatVersion)))
        }
        try Self.validateIdentifier(id)
        try Self.validateName(name)
        guard !steps.isEmpty else {
            throw ToolDefinitionError(reason: .noSteps)
        }
        guard steps.count <= ToolDefinitionLimits.maximumSteps else {
            throw ToolDefinitionError(reason: .tooManySteps(count: steps.count))
        }
        for (offset, step) in steps.enumerated() {
            try step.validate(stepNumber: offset + 1)
        }
    }

    // MARK: Decoding and encoding

    public static func decode(_ data: Data) throws -> ToolDefinition {
        guard data.count <= ToolDefinitionLimits.maximumFileBytes else {
            throw ToolDefinitionError(
                reason: .fileTooLarge(maximumKilobytes: ToolDefinitionLimits.maximumFileBytes / 1024))
        }
        do {
            return try JSONDecoder().decode(ToolDefinition.self, from: data)
        } catch let error as ToolDefinitionError {
            throw error
        } catch {
            throw ToolDefinitionError(reason: .unreadable)
        }
    }

    /// Reads a user-picked file through the same byte budget. Directories, missing files and
    /// remote URLs are rejected before anything is opened.
    public static func decode(contentsOf url: URL) throws -> ToolDefinition {
        guard url.isFileURL else {
            throw ToolDefinitionError(reason: .notAFile)
        }
        let resolved = url.resolvingSymlinksInPath()
        guard
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize
        else {
            throw ToolDefinitionError(reason: .notAFile)
        }
        guard size <= ToolDefinitionLimits.maximumFileBytes else {
            throw ToolDefinitionError(
                reason: .fileTooLarge(maximumKilobytes: ToolDefinitionLimits.maximumFileBytes / 1024))
        }
        guard let data = try? Data(contentsOf: resolved) else {
            throw ToolDefinitionError(reason: .unreadable)
        }
        return try decode(data)
    }

    /// Writes the definition back as version 1 JSON. Validation runs first so an invalid model is
    /// never exported.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: Validation helpers

    private static func validateIdentifier(_ id: String) throws {
        let valid =
            !id.isEmpty && id.utf8.count <= ToolDefinitionLimits.maximumIdentifierUTF8Bytes
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        guard valid else {
            throw ToolDefinitionError(reason: .invalidField(path: "$.id"))
        }
    }

    private static func validateName(_ name: [String: String]) throws {
        guard !name.isEmpty else {
            throw ToolDefinitionError(reason: .invalidField(path: "$.name"))
        }
        for tag in name.keys.sorted() {
            guard ToolDefinition.nameLanguageTags.contains(tag) else {
                throw ToolDefinitionError(reason: .invalidField(path: "$.name.\(tag)"))
            }
            let trimmed = name[tag]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, trimmed.count <= ToolDefinitionLimits.maximumNameCharacters else {
                throw ToolDefinitionError(reason: .invalidField(path: "$.name.\(tag)"))
            }
        }
    }

    /// Keeps the four defined languages, trims surrounding whitespace and drops every other tag.
    private static func normalizedName(_ raw: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (tag, value) in raw where ToolDefinition.nameLanguageTags.contains(tag) {
            result[tag] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

extension ToolDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case id
        case name
        case steps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard container.contains(.formatVersion) else {
            throw ToolDefinitionError(reason: .missingField(path: "$.formatVersion"))
        }
        guard let version = try? container.decode(Int.self, forKey: .formatVersion) else {
            throw ToolDefinitionError(reason: .invalidField(path: "$.formatVersion"))
        }
        guard version == ToolDefinition.formatVersion else {
            throw ToolDefinitionError(reason: .unsupportedFormatVersion(String(version)))
        }
        self.formatVersion = version

        guard container.contains(.id) else {
            throw ToolDefinitionError(reason: .missingField(path: "$.id"))
        }
        guard let id = try? container.decode(String.self, forKey: .id) else {
            throw ToolDefinitionError(reason: .invalidField(path: "$.id"))
        }
        self.id = id

        guard container.contains(.name) else {
            throw ToolDefinitionError(reason: .missingField(path: "$.name"))
        }
        guard let rawName = try? container.decode([String: String].self, forKey: .name) else {
            throw ToolDefinitionError(reason: .invalidField(path: "$.name"))
        }
        self.name = Self.normalizedName(rawName)

        guard container.contains(.steps) else {
            throw ToolDefinitionError(reason: .missingField(path: "$.steps"))
        }
        guard var stepContainer = try? container.nestedUnkeyedContainer(forKey: .steps) else {
            throw ToolDefinitionError(reason: .invalidField(path: "$.steps"))
        }
        var steps: [ToolStep] = []
        while !stepContainer.isAtEnd {
            let index = steps.count
            do {
                let stepKeys = try stepContainer.nestedContainer(keyedBy: DynamicCodingKey.self)
                steps.append(try ToolStep.decode(from: stepKeys, stepNumber: index + 1))
            } catch let error as ToolDefinitionError {
                throw error
            } catch {
                throw ToolDefinitionError(reason: .invalidField(path: "$.steps[\(index)]"))
            }
            guard steps.count <= ToolDefinitionLimits.maximumSteps else {
                throw ToolDefinitionError(reason: .tooManySteps(count: steps.count))
            }
        }
        self.steps = steps
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(steps, forKey: .steps)
    }
}

extension ToolStep: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case config
        case pattern
        case replacement
        case table
        case mode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .opencc(let config):
            try container.encode("opencc", forKey: .type)
            try container.encode(config.rawValue, forKey: .config)
        case .replace(let pattern, let replacement):
            try container.encode("replace", forKey: .type)
            try container.encode(pattern, forKey: .pattern)
            try container.encode(replacement, forKey: .replacement)
        case .map(let table):
            try container.encode("map", forKey: .type)
            try container.encode(table, forKey: .table)
        case .caseTransform(let mode):
            try container.encode("case", forKey: .type)
            try container.encode(mode.rawValue, forKey: .mode)
        case .width(let mode):
            try container.encode("width", forKey: .type)
            try container.encode(mode.rawValue, forKey: .mode)
        case .template(let pattern):
            try container.encode("template", forKey: .type)
            try container.encode(pattern, forKey: .pattern)
        }
    }

    static func decode(
        from container: KeyedDecodingContainer<DynamicCodingKey>, stepNumber: Int
    ) throws -> ToolStep {
        let path = "$.steps[\(stepNumber - 1)]"
        guard container.contains(DynamicCodingKey("type")) else {
            throw ToolDefinitionError(reason: .missingField(path: path + ".type"))
        }
        guard let type = try? container.decode(String.self, forKey: DynamicCodingKey("type")) else {
            throw ToolDefinitionError(reason: .invalidField(path: path + ".type"))
        }
        switch type {
        case "opencc":
            let config = try requireString(container, "config", path: path + ".config")
            guard let known = OpenCCToolConfig(rawValue: config) else {
                throw ToolDefinitionError(
                    reason: .unavailableOpenCCConfig(step: stepNumber, config: config))
            }
            return .opencc(config: known)
        case "replace":
            let pattern = try requireString(container, "pattern", path: path + ".pattern")
            let replacement = try requireString(container, "replacement", path: path + ".replacement")
            return .replace(pattern: pattern, replacement: replacement)
        case "map":
            let codingKey = DynamicCodingKey("table")
            guard container.contains(codingKey) else {
                throw ToolDefinitionError(reason: .missingField(path: path + ".table"))
            }
            guard let table = try? container.decode([String: String].self, forKey: codingKey) else {
                throw ToolDefinitionError(reason: .invalidField(path: path + ".table"))
            }
            return .map(table: table)
        case "case":
            let mode = try requireString(container, "mode", path: path + ".mode")
            guard let known = CaseMode(rawValue: mode) else {
                throw ToolDefinitionError(reason: .invalidField(path: path + ".mode"))
            }
            return .caseTransform(mode: known)
        case "width":
            let mode = try requireString(container, "mode", path: path + ".mode")
            guard let known = WidthMode(rawValue: mode) else {
                throw ToolDefinitionError(reason: .invalidField(path: path + ".mode"))
            }
            return .width(mode: known)
        case "template":
            let pattern = try requireString(container, "pattern", path: path + ".pattern")
            return .template(pattern: pattern)
        default:
            throw ToolDefinitionError(reason: .unsupportedStepType(step: stepNumber, type: type))
        }
    }

    private static func requireString(
        _ container: KeyedDecodingContainer<DynamicCodingKey>, _ key: String, path: String
    ) throws -> String {
        let codingKey = DynamicCodingKey(key)
        guard container.contains(codingKey) else {
            throw ToolDefinitionError(reason: .missingField(path: path))
        }
        guard let value = try? container.decode(String.self, forKey: codingKey) else {
            throw ToolDefinitionError(reason: .invalidField(path: path))
        }
        return value
    }

    func validate(stepNumber: Int) throws {
        let path = "$.steps[\(stepNumber - 1)]"
        switch self {
        case .opencc, .caseTransform, .width:
            break
        case .replace(let pattern, let replacement):
            try Self.validateRegex(pattern, path: path + ".pattern", stepNumber: stepNumber)
            guard replacement.utf16.count <= ToolDefinitionLimits.maximumReplacementUTF16CodeUnits else {
                throw ToolDefinitionError(reason: .invalidField(path: path + ".replacement"))
            }
        case .map(let table):
            guard !table.isEmpty, table.count <= ToolDefinitionLimits.maximumMapEntries else {
                throw ToolDefinitionError(reason: .invalidField(path: path + ".table"))
            }
            for key in table.keys.sorted() {
                let value = table[key] ?? ""
                guard key.count == 1, value.count <= ToolDefinitionLimits.maximumMapValueCharacters else {
                    throw ToolDefinitionError(reason: .invalidField(path: path + ".table.\(key)"))
                }
            }
        case .template(let pattern):
            guard
                !pattern.isEmpty,
                pattern.utf16.count <= ToolDefinitionLimits.maximumPatternUTF16CodeUnits,
                pattern.components(separatedBy: ToolDefinition.textPlaceholder).count == 2
            else {
                throw ToolDefinitionError(reason: .invalidField(path: path + ".pattern"))
            }
        }
    }

    private static func validateRegex(_ pattern: String, path: String, stepNumber: Int) throws {
        guard
            !pattern.isEmpty,
            pattern.utf16.count <= ToolDefinitionLimits.maximumPatternUTF16CodeUnits
        else {
            throw ToolDefinitionError(reason: .invalidField(path: path))
        }
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ToolDefinitionError(reason: .invalidRegex(step: stepNumber))
        }
    }
}

/// Decodes one step object without a fixed key set, so fields that belong to other step types
/// are ignored instead of rejected.
struct DynamicCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        nil
    }
}
