import Foundation
import Yams

/// Alias-bomb ("billion laughs") guard shared by every YAML read of imported or
/// installed scheme sources.
///
/// Yams' composer resolves an alias by reusing the anchored `Node` value, so the
/// composed tree is linear in the input size, but anything that *walks* or
/// *constructs* it (`Yams.load`, recursive visitors, key hashing) pays for the
/// fully expanded tree. Real Rime schemes (rime-ice etc.) use a handful of
/// `<<: *base` style aliases; we therefore cap the expanded node count instead of
/// banning aliases. Text without any alias token takes the unchanged fast path.
public enum BoundedYAML {
    /// Maximum number of nodes after alias expansion.
    public static let maximumExpandedNodes = 2_000_000
    /// Maximum number of alias tokens in one document.
    public static let maximumAliases = 100_000

    public struct LimitExceeded: Error, LocalizedError, Equatable {
        public let reason: String
        public var errorDescription: String? { PackageText.format("yaml.error.scaleExceeded", reason) }
    }

    /// Drop-in replacement for `Yams.load(yaml:)`.
    public static func load(yaml text: String) throws -> Any? {
        try lastKeyWins(text) { try strictLoad(yaml: $0) }
    }

    /// Drop-in replacement for `Yams.compose(yaml:)`; documents using aliases
    /// are guaranteed to expand to at most `maximumExpandedNodes` nodes.
    public static func compose(yaml text: String) throws -> Node? {
        try lastKeyWins(text) { try strictCompose(yaml: $0) }
    }

    /// Most repeated keys one document may have before it is refused.
    static let maximumDuplicateRepairs = 256

    /// librime reads YAML with yaml-cpp, where a key repeated in one mapping is not an error and
    /// the last one wins; real schemes ship such files (薄荷's `wubi86_jidian` repeats
    /// `enable_user_dict`). Yams refuses them, so each earlier occurrence is renamed to a key no
    /// Rime config reads and the text parsed again. The renaming only exists in this parse.
    ///
    /// `shadow` names an earlier occurrence from its key and how many occurrences follow it; the default
    /// is a placeholder no config reads. The user's own files rename each repeat to the key with
    /// `/=` after it, which a patch operator reads as the same key, so every pair is still checked.
    static func lastKeyWins<T>(
        _ text: String, shadow: ((String, Int) -> String)? = nil, _ parse: (String) throws -> T
    ) throws -> T {
        var current = text
        var repairs = 0
        while true {
            do {
                return try parse(current)
            } catch YamlError.duplicatedKeysInMapping(let duplicates, _) {
                var lines = current.components(separatedBy: "\n")
                var changed = false
                for (key, nodes) in duplicates {
                    guard let name = key.string, !name.isEmpty else { continue }
                    let earlier = nodes.compactMap(\.mark).sorted { ($0.line, $0.column) < ($1.line, $1.column) }
                        .dropLast()
                    // Right to left, so a rename never moves an occurrence still to come on the same line.
                    for (index, mark) in zip(earlier.indices, earlier).reversed() {
                        repairs += 1
                        guard repairs <= maximumDuplicateRepairs,
                            mark.line >= 1, mark.line <= lines.count
                        else {
                            throw LimitExceeded(
                                reason: PackageText.format("yaml.error.tooManyDuplicates", maximumDuplicateRepairs))
                        }
                        let line = lines[mark.line - 1]
                        let from = line.index(line.startIndex, offsetBy: min(mark.column - 1, line.count))
                        guard
                            let range = line.range(of: name, range: from..<line.endIndex)
                                ?? line.range(of: name)
                        else { continue }
                        var placeholder = ""
                        if let shadow {
                            placeholder = shadow(name, earlier.count - index)
                        } else {
                            repeat {
                                placeholder = "songyan_shadowed_" + UUID().uuidString.prefix(8)
                            } while current.contains(placeholder)
                        }
                        lines[mark.line - 1] = line.replacingCharacters(in: range, with: placeholder)
                        changed = true
                    }
                }
                guard changed else { throw YamlError.duplicatedKeysInMapping(duplicates: duplicates, yaml: current) }
                current = lines.joined(separator: "\n")
            }
        }
    }

    private static func strictLoad(yaml text: String) throws -> Any? {
        guard try requiresExpansionCheck(text) else { return try Yams.load(yaml: text) }
        guard let node = try Yams.compose(yaml: text) else { return nil }
        try checkExpandedSize(node)
        return node.any
    }

    /// Maximum size of the alias-free preflight text, before allocating it.
    static let maximumShadowBytes = 32 * 1024 * 1024

    static func strictCompose(yaml text: String) throws -> Node? {
        guard try requiresExpansionCheck(text) else { return try Yams.compose(yaml: text) }
        guard let node = try Yams.compose(yaml: text) else { return nil }
        try checkExpandedSize(node)
        return node
    }

    /// Parse an alias-free shadow before the original can reach Yams' composer.
    /// Yams 5.x hashes mapping keys during composition and exposes no public
    /// event stream, so checking only the composed original would be too late.
    ///
    /// Every `*` is replaced, including those in comments and scalar content.
    /// The replacement is an ordinary plain-scalar prefix; a real alias therefore
    /// becomes a plain scalar beginning with it. Yams, rather than a second YAML
    /// lexer, handles block indentation, quotes, plain continuations and Unicode
    /// names. Quoted/block scalars and stars inside plain text are not aliases.
    /// The shadow is never constructed or returned to callers.
    static func requiresExpansionCheck(_ text: String, maximumShadowBytes: Int = maximumShadowBytes) throws -> Bool {
        guard text.utf8.contains(0x2A) else { return false }
        let byteCount = text.utf8.count
        let sizeError = LimitExceeded(reason: PackageText.format("yaml.error.shadowBudget", maximumShadowBytes))
        guard byteCount <= maximumShadowBytes else { throw sizeError }
        // Use a short ASCII prefix, also legal inside YAML tags. An absent
        // random prefix avoids merging ordinary keys such as 'a*b' and 'axb'.
        // Eight ASCII characters limit growth and keep typical regex keys well
        // within YAML's simple-key length limit. Large inputs fail closed below.
        var prefix: String
        repeat {
            prefix = "Y" + UUID().uuidString.prefix(7)
        } while text.contains(prefix)
        let stars = text.utf8.reduce(0) { $0 + ($1 == 0x2A ? 1 : 0) }
        // Divide before multiplying: both integer overflow and a large temporary
        // allocation must be impossible even with attacker-controlled input.
        guard stars <= (maximumShadowBytes - byteCount) / (prefix.utf8.count - 1) else { throw sizeError }
        let shadow = text.replacingOccurrences(of: "*", with: prefix)
        guard let root = try Yams.compose(yaml: shadow) else { return false }
        func isAlias(_ scalar: Node.Scalar) -> Bool {
            scalar.style == .plain && scalar.string.hasPrefix(prefix)
        }
        var aliases = 0
        var unsupportedKey = false
        var visited = 0
        var stack = [root]
        while let node = stack.popLast() {
            visited += 1
            if visited & 0xFFF == 0 { try Task.checkCancellation() }
            switch node {
            case .scalar(let scalar):
                if isAlias(scalar) {
                    aliases += 1
                    guard aliases <= maximumAliases else {
                        throw LimitExceeded(reason: PackageText.format("yaml.error.tooManyAliases", maximumAliases))
                    }
                }
            case .mapping(let mapping):
                for (key, value) in mapping {
                    if case .scalar(let scalar) = key {
                        unsupportedKey = unsupportedKey || isAlias(scalar)
                    } else {
                        unsupportedKey = true
                    }
                    stack.append(key)
                    stack.append(value)
                }
            case .sequence(let sequence):
                stack.append(contentsOf: sequence)
            default:
                break
            }
        }
        guard aliases > 0 else { return false }
        // Collection keys may contain aliases anywhere in their descendants;
        // reject them before composing the original, regardless of key syntax.
        if unsupportedKey { throw LimitExceeded(reason: PackageText.string("yaml.error.unsupportedKey")) }
        return true
    }

    /// Iterative walk with an early abort; never visits more than the budget.
    static func checkExpandedSize(_ root: Node, maximumExpandedNodes: Int = maximumExpandedNodes) throws {
        var stack: [Node] = [root]
        var count = 0
        while let node = stack.popLast() {
            count += 1
            if count > maximumExpandedNodes {
                throw LimitExceeded(
                    reason: PackageText.format("yaml.error.tooManyExpandedNodes", maximumExpandedNodes))
            }
            if count & 0xFFF == 0 { try Task.checkCancellation() }
            switch node {
            case .mapping(let mapping):
                for (key, value) in mapping {
                    stack.append(key)
                    stack.append(value)
                }
            case .sequence(let sequence):
                stack.append(contentsOf: sequence)
            default:
                break
            }
        }
    }

    /// A document read as text, the way librime's yaml-cpp reads what a file names: every scalar, key
    /// or value, is its text whatever tag it carries (`!!null x` stays `x`), and mappings keep their order.
    enum TextNode {
        case scalar(String)
        case list([TextNode])
        case map([(key: String, value: TextNode)])

        var isCollection: Bool {
            if case .scalar = self { return false }
            return true
        }
    }

    /// Most nodes `loadAsText` converts.
    static let maximumTextNodes = 500_000

    /// For the user's own files and the compiled build files. A key a mapping repeats is kept too, as
    /// `key/=`, `key/=/=`: yaml-cpp keeps every pair and librime acts on each (every `__patch` and
    /// `__include`), so a check must see each one. A key that is not a scalar is dropped.
    static func loadAsText(yaml text: String) throws -> TextNode? {
        guard
            let root = try lastKeyWins(
                text, shadow: { name, following in name + String(repeating: "/=", count: following) },
                { try strictCompose(yaml: $0) })
        else { return nil }
        var budget = maximumTextNodes
        func convert(_ node: Node) throws -> TextNode? {
            budget -= 1
            guard budget >= 0 else {
                throw LimitExceeded(
                    reason: PackageText.format("yaml.error.tooManyTextNodes", maximumTextNodes))
            }
            if budget & 0xFFF == 0 { try Task.checkCancellation() }
            switch node {
            case .scalar(let scalar):
                return .scalar(scalar.string)
            case .sequence(let sequence):
                return .list(try sequence.compactMap { try convert($0) })
            case .mapping(let mapping):
                var entries: [(key: String, value: TextNode)] = []
                for (key, value) in mapping {
                    guard case .scalar(let name) = key, let converted = try convert(value) else { continue }
                    entries.append((name.string, converted))
                }
                return .map(entries)
            case .alias:
                return nil
            }
        }
        return try convert(root)
    }

    /// The 1-based line a parse error points at, when the parser says.
    static func errorLine(_ error: Error) -> Int? {
        switch error as? YamlError {
        case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _): return mark.line
        case .duplicatedKeysInMapping(let duplicates, _):
            return duplicates.values.flatMap { $0 }.compactMap(\.mark?.line).min()
        default: return nil
        }
    }
}
