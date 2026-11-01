import Foundation

/// What the user's own configuration files may name and how deep they may nest, checked on the
/// parsed document and never by following anything in it. The files are untrusted (any app the
/// user lets into the Files folder can write them), and librime opens whatever file name a config
/// value gives it, so a name that leaves the data folders is refused before a deployment sees it.
enum UserConfigSafety {
    /// More nested flow collections than any real configuration has; librime's reader recurses on them.
    static let maximumFlowDepth = 64
    private static let maximumNodes = 1_000_000
    private static let maximumPathBytes = 1024
    private static let maximumPathDepth = 32
    private static let maximumComponentBytes = 255

    /// Config keys whose value names a file (or a database) librime opens, by the last part of the key.
    static let fileKeys: Set<String> = [
        "import_preset", "dictionary", "prism", "user_dict", "vocabulary", "opencc_config", "import_tables", "db",
        "language", "schema", "dependencies", "packs",
    ]
    private static let luaKinds = ["lua_processor", "lua_translator", "lua_filter", "lua_segmentor"]

    /// Whether `path` is a relative path a package or the user's folder may hold.
    static func safePath(_ path: String) -> Bool {
        let components = path.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
        return SchemeSourceCheck.safe(path) && path.utf8.count <= maximumPathBytes
            && components.count <= maximumPathDepth && components.allSatisfy { $0.count <= maximumComponentBytes }
    }

    /// Whether the text nests flow collections (`[`, `{`) deeper than `maximumFlowDepth`, outside comments and quotes.
    static func tooDeep(_ text: String) -> Bool {
        var depth = 0
        var quote: UInt8 = 0
        var previous: UInt8 = 0x20
        var previousSignificant: UInt8 = 0x0A
        var inComment = false
        for byte in text.utf8 {
            if byte == 0x0A || byte == 0x0D {
                // Quotes and comments end with their line, as the checks read one line at a time.
                quote = 0
                inComment = false
                previous = 0x20
                previousSignificant = 0x0A
                continue
            }
            if inComment { continue }
            if quote != 0 {
                if byte == quote { quote = 0 }
            } else if byte == UInt8(ascii: "#") && isSpace(previous) {
                inComment = true
                continue
            } else if (byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'"))
                && scalarStarts.contains(previousSignificant)
            {
                quote = byte
            } else if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") {
                depth += 1
                if depth > maximumFlowDepth { return true }
            } else if (byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}")) && depth > 0 {
                depth -= 1
            }
            previous = byte
            if !isSpace(byte) { previousSignificant = byte }
        }
        return false
    }

    /// What a quote can follow, for it to begin a scalar.
    private static let scalarStarts: Set<UInt8> = Set("\n:,[{-?".utf8)

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    /// The first value in the parsed document that names a file outside the data folders (or is not a
    /// plain relative name), or nil. Covers include and patch references (`file:/node`), `import_preset`,
    /// `dictionary`, `import_tables`, `prism`, `packs`, `user_dict`, `vocabulary`, `opencc_config`, `db`,
    /// `grammar/language`, `schema` (a `schema_list` entry) and `dependencies`. Patch operators do not hide
    /// a key: `a/user_dict/=`, `a/user_dict/+` and list selectors (`@0`, `@last`, `@before 1`, `@after 1`,
    /// `@next`) are read as the key they act on. A scalar given to `/+`, `__append` or `__merge` is refused
    /// for every key, because strings built from pieces (a name, a path, a component) are not what Rime
    /// appends to; lists are.
    /// The same walk over a compiled build file finds the keys at their real paths.
    static func unsafeReference(_ root: BoundedYAML.TextNode?) -> String? {
        var budget = maximumNodes
        var stack: [BoundedYAML.TextNode] = root.map { [$0] } ?? []
        while let node = stack.popLast() {
            budget -= 1
            if budget < 0 { return "too many nodes" }
            switch node {
            case .map(let entries):
                for entry in entries {
                    if let problem = unsafeEntry(entry.key, entry.value) { return problem }
                    if entry.value.isCollection { stack.append(entry.value) }
                }
            case .list(let items):
                stack.append(contentsOf: items.filter(\.isCollection))
            case .scalar:
                break
            }
        }
        return nil
    }

    private static func unsafeEntry(_ key: String, _ value: BoundedYAML.TextNode) -> String? {
        // A repeated key arrives as `key/=`: the same key again.
        // Every separator is read on the bytes librime reads: a combining mark after `/` or `:` must not hide it.
        var base = key
        while base.utf8HasSuffix("/=") { base = String(decoding: base.utf8.dropLast(2), as: UTF8.self) }
        if base.utf8Equals("__include") || base.utf8Equals("__patch") { return firstUnsafeReference(value) }
        let parts = key.utf8.split(separator: 0x2F, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        // A string can be built from pieces (`@next: lu`, then `@last/+: a_filter@*x`): lists are what Rime appends to.
        let appends = parts.last?.utf8Equals("+") == true
        if case .scalar = value, appends || base.utf8Equals("__append") || base.utf8Equals("__merge") { return key }
        // The key the operators act on: without `=`, `+` and list selectors.
        guard
            let name = parts.last(where: {
                !$0.isEmpty && !$0.utf8Equals("=") && !$0.utf8Equals("+") && !$0.utf8HasPrefix("@")
            }),
            fileKeys.contains(name)
        else { return nil }
        return firstUnsafeName(value)
    }

    /// Every Lua component entry (`lua_filter@name`, `lua_translator@*module`, a bare `lua_filter`) among
    /// the scalar values of the parsed document, sorted. Keys are not entries.
    static func luaComponents(_ root: BoundedYAML.TextNode?) -> [String] {
        var found = Set<String>()
        var budget = maximumNodes
        var stack: [BoundedYAML.TextNode] = root.map { [$0] } ?? []
        while let node = stack.popLast(), budget > 0 {
            budget -= 1
            switch node {
            case .map(let entries): stack.append(contentsOf: entries.map(\.value))
            case .list(let items): stack.append(contentsOf: items)
            case .scalar(let text): if isLuaComponent(text) { found.insert(text.trimmingCharacters(in: .whitespaces)) }
            }
        }
        return found.sorted()
    }

    static func isLuaComponent(_ text: String) -> Bool {
        luaKinds.contains { kind in
            guard text.utf8HasPrefix(kind) else { return false }
            let rest = text.utf8.dropFirst(kind.utf8.count)
            return rest.isEmpty || rest.first == 0x40
        }
    }

    /// The files the document includes or patches from (`__include`, `__patch`), as paths with `.yaml`,
    /// for the safe references among them.
    static func fileReferences(_ root: BoundedYAML.TextNode?) -> Set<String> {
        var found = Set<String>()
        var budget = maximumNodes
        var stack: [BoundedYAML.TextNode] = root.map { [$0] } ?? []
        func collect(_ value: BoundedYAML.TextNode) {
            switch value {
            case .list(let items): items.forEach(collect)
            case .map: break
            case .scalar(let text):
                guard let name = filePart(of: text) else { return }
                let file = name.utf8HasSuffix(".yaml") ? name : name + ".yaml"
                if SchemeSourceCheck.safe(file) { found.insert(file) }
            }
        }
        while let node = stack.popLast() {
            budget -= 1
            if budget < 0 { break }
            switch node {
            case .map(let entries):
                for entry in entries {
                    var base = entry.key
                    while base.utf8HasSuffix("/=") { base = String(decoding: base.utf8.dropLast(2), as: UTF8.self) }
                    if base.utf8Equals("__include") || base.utf8Equals("__patch") { collect(entry.value) }
                    if entry.value.isCollection { stack.append(entry.value) }
                }
            case .list(let items): stack.append(contentsOf: items.filter(\.isCollection))
            case .scalar: break
            }
        }
        return found
    }

    /// A `file:/node` reference (or a list of them, as `__patch` takes) whose file part is unsafe, or nil.
    private static func firstUnsafeReference(_ value: BoundedYAML.TextNode) -> String? {
        switch value {
        case .list(let items): return items.lazy.compactMap { firstUnsafeReference($0) }.first
        case .map: return nil
        case .scalar(let text):
            // Without a file part the reference is to the file itself.
            guard let name = filePart(of: text) else { return nil }
            let file = name.utf8HasSuffix(".yaml") ? name : name + ".yaml"
            return !SchemeSourceCheck.safe(file) || !safePath(file) ? text : nil
        }
    }

    /// The file part of a `file:/node` reference, split at the first `:` byte as librime splits it; nil
    /// when there is none (the reference is to the file itself) or the file part is empty.
    static func filePart(of reference: String) -> String? {
        guard let colon = reference.utf8.firstIndex(of: 0x3A), colon != reference.utf8.startIndex else { return nil }
        return String(decoding: reference.utf8[..<colon], as: UTF8.self)
    }

    private static func firstUnsafeName(_ value: BoundedYAML.TextNode) -> String? {
        switch value {
        case .list(let items): return items.lazy.compactMap { firstUnsafeName($0) }.first
        case .map(let entries):
            // `{__append: [x]}` / `{__merge: [x]}` spell the same value another way.
            return entries.lazy.filter { $0.key.utf8HasPrefix("__") }.compactMap { firstUnsafeName($0.value) }.first
        case .scalar(let text):
            return !text.isEmpty && (!SchemeSourceCheck.safe(text) || !safePath(text)) ? text : nil
        }
    }
}

extension String {
    /// Byte-wise comparisons: `String`'s own `hasPrefix`, `==` and `contains` work on grapheme clusters,
    /// where a combining mark after `:` or `@` hides it from the check but not from librime.
    func utf8HasPrefix(_ prefix: String) -> Bool { utf8.starts(with: prefix.utf8) }
    func utf8HasSuffix(_ suffix: String) -> Bool { utf8.reversed().starts(with: suffix.utf8.reversed()) }
    func utf8Equals(_ other: String) -> Bool { utf8.elementsEqual(other.utf8) }
}
