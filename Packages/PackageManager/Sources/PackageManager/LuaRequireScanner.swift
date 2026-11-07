/// Reads the `require` calls of a Lua source lexically. Comments and string literals are skipped
/// whole, so text inside them never names a dependency; a real call still names one when whitespace,
/// comments or parentheses sit between its tokens. Only a string-literal argument counts: a computed
/// argument cannot be resolved to a file, and a name outside the module path characters is left out
/// so the set of accepted names stays what the installer always accepted.
///
/// The scan works on the UTF-8 bytes: Lua's syntax is ASCII, and no UTF-8 continuation byte can equal
/// a quote, backslash or line break, so multibyte text inside strings and comments is skipped safely.
enum LuaRequireScanner {
    /// Module names required by string literals, in source order.
    static func modules(in source: String) -> [String] {
        var cursor = Cursor(Array(source.utf8))
        var modules: [String] = []
        while let name = cursor.nextName() {
            guard name == "require" else { continue }
            if let module = cursor.requiredModule() { modules.append(module) }
        }
        return modules
    }
}

/// A forward-only reader over one Lua source. Lua's lexer is small enough to follow directly: names,
/// short and long strings, short and long comments, and punctuation are all it has to tell apart.
private struct Cursor {
    private let bytes: [UInt8]
    private var index: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        index = 0
    }

    /// The next Lua name, skipping comments, strings and punctuation.
    mutating func nextName() -> String? {
        while index < bytes.count {
            if isCommentStart(at: index) {
                skipComment()
                continue
            }
            if isQuote(bytes[index]) {
                skipShortString()
                continue
            }
            if bytes[index] == Self.openBracket, longBracketLevel(at: index) != nil {
                skipLongBracket()
                continue
            }
            if Self.isNameStart(bytes[index]) {
                let start = index
                index += 1
                while index < bytes.count, Self.isNamePart(bytes[index]) { index += 1 }
                return String(decoding: bytes[start..<index], as: UTF8.self)
            }
            index += 1
        }
        return nil
    }

    /// The module a `require` call names, when its argument is a plain string literal.
    mutating func requiredModule() -> String? {
        skipTrivia()
        if index < bytes.count, bytes[index] == Self.openParen {
            index += 1
            skipTrivia()
        }
        guard let (literal, next) = readStringLiteral() else { return nil }
        index = next
        guard !literal.isEmpty, literal.allSatisfy(Self.isModuleByte) else { return nil }
        return String(decoding: literal, as: UTF8.self)
    }

    // MARK: - Trivia

    private mutating func skipTrivia() {
        while index < bytes.count {
            if Self.isWhitespace(bytes[index]) {
                index += 1
                continue
            }
            if isCommentStart(at: index) {
                skipComment()
                continue
            }
            return
        }
    }

    private mutating func skipComment() {
        index += 2
        if index < bytes.count, bytes[index] == Self.openBracket, longBracketLevel(at: index) != nil {
            skipLongBracket()
            return
        }
        while index < bytes.count, bytes[index] != Self.lineFeed, bytes[index] != Self.carriageReturn {
            index += 1
        }
    }

    // MARK: - Strings

    private mutating func skipShortString() {
        let quote = bytes[index]
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == Self.backslash {
                index += 2
                continue
            }
            if byte == quote {
                index += 1
                return
            }
            if byte == Self.lineFeed || byte == Self.carriageReturn { return }
            index += 1
        }
    }

    private mutating func skipLongBracket() {
        guard let (_, next) = readLongBracket(at: index) else {
            index += 1
            return
        }
        index = next
    }

    /// The literal's bytes and the position after it, when this is a plain string literal.
    private func readStringLiteral() -> ([UInt8], Int)? {
        guard index < bytes.count else { return nil }
        if bytes[index] == Self.openBracket { return readLongBracket(at: index) }
        guard isQuote(bytes[index]) else { return nil }
        let quote = bytes[index]
        var cursor = index + 1
        var value: [UInt8] = []
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == quote { return (value, cursor + 1) }
            // An escape or a raw line break means the argument is not a plain module name; leave the
            // call unreported rather than guessing what it loads.
            if byte == Self.backslash || byte == Self.lineFeed || byte == Self.carriageReturn {
                return nil
            }
            value.append(byte)
            cursor += 1
        }
        return nil
    }

    /// The content of a long string `[=*[` ... `]=*]` and the position after it.
    private func readLongBracket(at position: Int) -> ([UInt8], Int)? {
        guard let level = longBracketLevel(at: position) else { return nil }
        let contentStart = position + level + 2
        var cursor = contentStart
        while cursor < bytes.count {
            if bytes[cursor] == Self.closeBracket, let close = longBracketEnd(at: cursor, level: level) {
                return (Array(bytes[contentStart..<cursor]), close)
            }
            cursor += 1
        }
        return (Array(bytes[contentStart..<bytes.count]), bytes.count)
    }

    // MARK: - Long brackets

    /// The level of a long bracket opening `[=*[` at `position`, or nil when it is an index instead.
    private func longBracketLevel(at position: Int) -> Int? {
        guard position < bytes.count, bytes[position] == Self.openBracket else { return nil }
        var cursor = position + 1
        var level = 0
        while cursor < bytes.count, bytes[cursor] == Self.equalsSign {
            level += 1
            cursor += 1
        }
        guard cursor < bytes.count, bytes[cursor] == Self.openBracket else { return nil }
        return level
    }

    /// The position after the closing `]=*]` of the long bracket opening before it.
    private func longBracketEnd(at position: Int, level: Int) -> Int? {
        var cursor = position + 1
        var equals = 0
        while cursor < bytes.count, bytes[cursor] == Self.equalsSign {
            equals += 1
            cursor += 1
        }
        guard equals == level, cursor < bytes.count, bytes[cursor] == Self.closeBracket else { return nil }
        return cursor + 1
    }

    // MARK: - Bytes

    private func isCommentStart(at position: Int) -> Bool {
        guard position + 1 < bytes.count else { return false }
        return bytes[position] == Self.hyphen && bytes[position + 1] == Self.hyphen
    }

    private func isQuote(_ byte: UInt8) -> Bool {
        byte == Self.doubleQuote || byte == Self.singleQuote
    }

    private static func isNameStart(_ byte: UInt8) -> Bool {
        byte == Self.underscore || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isNamePart(_ byte: UInt8) -> Bool {
        isNameStart(byte) || (byte >= 0x30 && byte <= 0x39)
    }

    /// The bytes a module path may use, matching what the installer has always accepted.
    private static func isModuleByte(_ byte: UInt8) -> Bool {
        isNamePart(byte) || byte == 0x2E || byte == 0x2F || byte == 0x2D
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0B || byte == 0x0C || byte == 0x0D
    }

    private static let hyphen: UInt8 = 0x2D
    private static let openParen: UInt8 = 0x28
    private static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
    private static let equalsSign: UInt8 = 0x3D
    private static let underscore: UInt8 = 0x5F
    private static let doubleQuote: UInt8 = 0x22
    private static let singleQuote: UInt8 = 0x27
    private static let backslash: UInt8 = 0x5C
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
}
