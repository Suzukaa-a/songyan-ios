import Foundation

/// What a schema's own speller says about the keys it is typed on: which codes it needs and what
/// kind of coding that is. Layouts are offered by comparing this with the codes they send, so a
/// scheme whose letters a 26-key board does not cover never gets a board that silently drops them.
public struct SchemaKeyProfile: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Spelled syllable by syllable (pinyin, zhuyin, jyutping): folded 14/18/9-key layouts can run it.
        case syllabic
        /// One code per character part (wubi, English): only layouts that send each code can run it.
        case shapeCode
        /// A handful of stroke symbols mapped to captions by the scheme.
        case strokes
        /// No speller or no translator that is provably the primary one.
        case unknown

        // "nonLatin" was a kind of the shared fixtures before alphabets beyond ASCII were typed
        // through the same speller as any other; it reads as syllabic. A kind this build does not
        // know reads as unknown, so a newer file never breaks an older reader.
        public init(from decoder: any Decoder) throws {
            let wire = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: wire) ?? (wire == "nonLatin" ? .syllabic : .unknown)
        }
    }

    public struct Stroke: Codable, Equatable, Sendable {
        public let code: String
        public let label: String
        public init(code: String, label: String) {
            self.code = code
            self.label = label
        }
    }

    public let kind: Kind
    /// The codes the speller needs, in declared order, without duplicates.
    public let codes: [String]
    /// The stroke keys with their captions; only for `.strokes`.
    public let strokes: [Stroke]
    /// The language the dictionary is written in, read at deployment: `zh-Hans`, `zh-Hant`, `ja`, `ko`, `zh`
    /// (Chinese in both scripts: the system's decides) or `none` (nothing to force); nil when not read.
    public let language: String?
    /// The part of `codes` that only the delimiter, a translator's prefix or suffix, or a recognizer pattern
    /// names: a layout may go without them. The rest (the speller's alphabet and initials) a layout must send
    /// to type the scheme at all. Nil when the profile predates the split.
    public let optionalCodes: [String]?
    /// The version of the rule that produced `optionalCodes`; a profile written under an older one is read again.
    public let optionalRevision: Int?

    /// The version of the rule that sorts codes into required and optional; bumped whenever it changes.
    public static let currentOptionalRevision = 2

    /// Whether `optionalCodes` came from the rule in force now.
    public var optionalCodesAreCurrent: Bool { optionalRevision == Self.currentOptionalRevision }

    public init(
        kind: Kind, codes: [String] = [], strokes: [Stroke] = [], language: String? = nil,
        optionalCodes: [String]? = nil, optionalRevision: Int? = nil
    ) {
        self.kind = kind
        self.codes = codes
        self.strokes = strokes
        self.language = language
        self.optionalCodes = optionalCodes
        self.optionalRevision = optionalRevision
    }

    private enum CodingKeys: String, CodingKey { case kind, codes, strokes, language, optionalCodes, optionalRevision }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        codes = try values.decodeIfPresent([String].self, forKey: .codes) ?? []
        strokes = try values.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
        language = try values.decodeIfPresent(String.self, forKey: .language)
        optionalCodes = try values.decodeIfPresent([String].self, forKey: .optionalCodes)
        optionalRevision = try values.decodeIfPresent(Int.self, forKey: .optionalRevision)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        if !codes.isEmpty { try values.encode(codes, forKey: .codes) }
        if !strokes.isEmpty { try values.encode(strokes, forKey: .strokes) }
        try values.encodeIfPresent(language, forKey: .language)
        try values.encodeIfPresent(optionalCodes, forKey: .optionalCodes)
        try values.encodeIfPresent(optionalRevision, forKey: .optionalRevision)
    }

    /// Whether the folded 14/18/9-key layouts can be generated for this scheme.
    public var allowsFolding: Bool { kind == .syllabic }

    /// File name inside a build directory.
    public static let fileName = "key-profiles.json"

    public static func encode(_ profiles: [String: SchemaKeyProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(profiles)
    }

    public static func decode(_ data: Data) -> [String: SchemaKeyProfile]? {
        try? JSONDecoder().decode([String: SchemaKeyProfile].self, from: data)
    }

    public static func decodeOne(_ data: Data) -> SchemaKeyProfile? {
        try? JSONDecoder().decode(SchemaKeyProfile.self, from: data)
    }
}
