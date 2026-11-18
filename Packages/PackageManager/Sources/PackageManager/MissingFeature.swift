import Foundation

/// Something a package's input methods go without because a file they refer to is neither in the
/// package nor in another installed one: librime deploys them anyway, as on a desktop. `names` are
/// the missing schemas or dictionaries by name (`pinyin_simp`), or file paths for `.other`.
public struct MissingFeature: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Looking a character up by another input method's code.
        case reverseLookup
        /// The shared word list (`essay.txt`) a dictionary adds to its own.
        case presetVocabulary
        /// A dictionary only a script component or an unused section names.
        case other
    }

    public let kind: Kind
    public let names: [String]

    public init(kind: Kind, names: [String]) {
        self.kind = kind
        self.names = names
    }

    /// Where the well-known shared Rime packages live, for telling the user what to add.
    private static let repositories: [String: String] = [
        "stroke": "rime/rime-stroke",
        "luna_pinyin": "rime/rime-luna-pinyin",
        "pinyin_simp": "rime/rime-pinyin-simp",
        "terra_pinyin": "rime/rime-terra-pinyin",
        "cangjie5": "rime/rime-cangjie",
        "essay": "rime/rime-essay",
        "bopomofo": "rime/rime-bopomofo",
        "jyut6ping3": "rime/rime-cantonese",
        "wubi86": "rime/rime-wubi",
        "quick5": "rime/rime-quick",
        "double_pinyin": "rime/rime-double-pinyin",
    ]

    /// The upstream repository that provides `name`, when it is one of the well-known ones.
    public static func repository(of name: String) -> String? { repositories[name] }

    /// `file` (`terra_pinyin.dict.yaml`) followed by the upstream repository that provides it, when
    /// it is one of the well-known ones.
    public static func named(file path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return repository(of: stem(name)).map { "\(name)（\($0)）" } ?? name
    }

    /// The notice for this gap: what does not work, and which names are missing.
    public var userFacingDescription: String {
        let list = names.map { name in
            repositoryName(name).map { "\(name)（\($0)）" } ?? name
        }.joined(separator: "、")
        switch kind {
        case .reverseLookup: return PackageText.format("missingFeature.reverseLookup", list)
        case .presetVocabulary: return PackageText.format("missingFeature.presetVocabulary", list)
        case .other: return PackageText.format("missingFeature.other", list)
        }
    }

    /// What the user can do about every notice in `features`.
    public static var remedy: String { PackageText.string("missingFeature.remedy") }

    private func repositoryName(_ name: String) -> String? {
        kind == .other ? nil : Self.repository(of: name)
    }

    /// Groups a closure's optional gaps by what they cost the user.
    static func of(_ closure: SchemeSourceCheck.DependencyClosure) -> [MissingFeature] {
        // A scheme that another package of the tree declares as its own lookup is as unmet as one the
        // package names itself.
        let declared = closure.optional.filter { !closure.direct.contains($0) && $0.hasSuffix(".schema.yaml") }
        let lookup = Set((closure.lookups + declared).map(stem)).sorted()
        let vocabulary = closure.optional.filter { $0 == presetVocabularyFile }.map(stem)
        let other = closure.direct.filter {
            !closure.lookups.contains($0) && $0 != presetVocabularyFile && !lookup.contains(stem($0))
        }
        return [
            lookup.isEmpty ? nil : MissingFeature(kind: .reverseLookup, names: lookup),
            vocabulary.isEmpty ? nil : MissingFeature(kind: .presetVocabulary, names: vocabulary),
            other.isEmpty ? nil : MissingFeature(kind: .other, names: other),
        ].compactMap { $0 }
    }

    private static let presetVocabularyFile = "essay.txt"

    private static func stem(_ path: String) -> String {
        var name = path.split(separator: "/").last.map(String.init) ?? path
        for suffix in [".schema.yaml", ".dict.yaml", ".txt"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }
}
