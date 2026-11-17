import Foundation
import KeyboardCore

/// Reads a `SchemaKeyProfile` from a compiled schema: the speller's alphabet, initials and
/// delimiter, the prefixes and suffixes of its translators, and the literal heads of the recognizer
/// patterns that route input to one of them. The primary translator, as in `CompactSchemaAdapter`,
/// decides the kind.
public enum SchemaKeyProfiles {
    private static let defaultAlphabet = "abcdefghijklmnopqrstuvwxyz"
    private static let defaultDelimiter = " '"
    private static let maximumStrokes = 5
    private static let maximumFileBytes = 1 << 20
    private static let unknown = SchemaKeyProfile(kind: .unknown)

    /// Never throws: a schema that cannot be read has an unknown profile.
    public static func compute(compiledSchema text: String) -> SchemaKeyProfile {
        guard let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any],
            let engine = root["engine"] as? [String: Any]
        else { return unknown }
        let processors = stringList(engine["processors"])
        let translators = stringList(engine["translators"])
        guard processors.contains("speller"),
            let primary = CompactSchemaAdapter.primaryProducer(translators: translators)
        else { return unknown }

        let speller = root["speller"] as? [String: Any] ?? [:]
        let alphabet = speller["alphabet"] as? String ?? defaultAlphabet
        var codes: [String] = []
        var seen = Set<String>()
        func add(_ text: String?) {
            for scalar in text?.unicodeScalars ?? "".unicodeScalars where scalar != " " {
                let code = String(scalar)
                if seen.insert(code).inserted { codes.append(code) }
            }
        }
        add(alphabet)
        add(speller["initials"] as? String)
        add(speller["delimiter"] as? String ?? defaultDelimiter)

        let namespaces = namespacesOf(translators)
        for (namespace, _) in namespaces {
            guard let section = root[namespace] as? [String: Any] else { continue }
            add(section["prefix"] as? String)
            add(section["suffix"] as? String)
        }
        var tags = Set<String>()
        for (namespace, defaultTag) in namespaces {
            tags.insert((root[namespace] as? [String: Any])?["tag"] as? String ?? defaultTag)
        }
        tags.formUnion(stringList((root["abc_segmentor"] as? [String: Any])?["extra_tags"]))
        let patterns = (root["recognizer"] as? [String: Any])?["patterns"] as? [String: Any] ?? [:]
        // Dictionary order of a parsed map is not declared order; sort so the result is stable.
        for tag in patterns.keys.sorted() where tags.contains(tag) {
            if let pattern = patterns[tag] as? String { add(literalHead(pattern)) }
        }

        if primary.klass == .script { return SchemaKeyProfile(kind: .syllabic, codes: codes) }
        let strokes = strokeCaptions(root[primary.namespace] as? [String: Any], alphabet: alphabet)
        if strokes.isEmpty { return SchemaKeyProfile(kind: .shapeCode, codes: codes) }
        let strokeCodes = strokes.map(\.code)
        let rest = codes.filter { code in
            !strokeCodes.contains(code) && !(code.unicodeScalars.first?.properties.isAlphabetic ?? false)
        }
        return SchemaKeyProfile(kind: .strokes, codes: strokeCodes + rest, strokes: strokes)
    }

    /// The profiles of every `<id>.schema.yaml` in `buildDir` that `ids` names; unreadable ones are unknown.
    public static func computeAll(buildDir: URL, ids: [String]) -> [String: SchemaKeyProfile] {
        var result: [String: SchemaKeyProfile] = [:]
        for id in ids {
            let file = buildDir.appendingPathComponent("\(id).schema.yaml")
            if let data = boundedRead(file, limit: RecipeResourceBudget.sourceFile),
                let text = String(data: data, encoding: .utf8)
            {
                result[id] = compute(compiledSchema: text)
            } else {
                result[id] = unknown
            }
        }
        return result
    }

    /// The profiles of `ids` in `buildDir`: the ones the deployment wrote, and for a build published
    /// before profiles existed (or a schema the file lacks) the ones computed from its compiled
    /// schema. Reads the disk; call off the main thread.
    public static func read(buildDir: URL, ids: [String]) -> [String: SchemaKeyProfile] {
        let file = buildDir.appendingPathComponent(SchemaKeyProfile.fileName)
        let written = boundedRead(file, limit: maximumFileBytes).flatMap(SchemaKeyProfile.decode) ?? [:]
        let wanted = Set(ids)
        var result = written.filter { wanted.contains($0.key) }
        for (id, profile) in computeAll(buildDir: buildDir, ids: ids.filter { written[$0] == nil }) {
            result[id] = profile
        }
        return result
    }

    /// Writes the profiles of `ids` next to the compiled schemas of `buildDir`.
    public static func write(buildDir: URL, ids: [String]) throws {
        try write(computeAll(buildDir: buildDir, ids: ids), buildDir: buildDir)
    }

    /// `profiles` with the language of each primary dictionary read from `sourceDirectories` (the first
    /// one holding the file wins).
    public static func withLanguages(
        _ profiles: [String: SchemaKeyProfile], buildDir: URL, sourceDirectories: [URL]
    ) -> [String: SchemaKeyProfile] {
        var result = profiles
        for (id, profile) in profiles {
            let language = primaryDictionary(buildDir: buildDir, id: id).flatMap { name in
                sourceDirectories.lazy.compactMap { DictionaryLanguage.read(sourceDirectory: $0, name: name) }.first
            }
            result[id] = SchemaKeyProfile(
                kind: profile.kind, codes: profile.codes, strokes: profile.strokes, language: language)
        }
        return result
    }

    /// The dictionary the primary script or table translator of a compiled schema reads.
    static func primaryDictionary(compiledSchema text: String) -> String? {
        guard let root = (try? BoundedYAML.load(yaml: text)) as? [String: Any],
            let engine = root["engine"] as? [String: Any],
            let primary = CompactSchemaAdapter.primaryProducer(translators: stringList(engine["translators"]))
        else { return nil }
        return (root[primary.namespace] as? [String: Any])?["dictionary"] as? String
    }

    private static func primaryDictionary(buildDir: URL, id: String) -> String? {
        boundedRead(buildDir.appendingPathComponent("\(id).schema.yaml"), limit: RecipeResourceBudget.sourceFile)
            .flatMap { String(data: $0, encoding: .utf8) }.flatMap { primaryDictionary(compiledSchema: $0) }
    }

    public static func write(_ profiles: [String: SchemaKeyProfile], buildDir: URL) throws {
        try SchemaKeyProfile.encode(profiles)
            .write(to: buildDir.appendingPathComponent(SchemaKeyProfile.fileName), options: .atomic)
    }

    private static func boundedRead(_ file: URL, limit: Int) -> Data? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit else {
            return nil
        }
        return try? Data(contentsOf: file)
    }

    private static func stringList(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The sections that carry translator settings with the tag each one routes: the unnamed script,
    /// table and reverse-lookup translators and every `class@name` one. Lua entries written
    /// `@*module` have no section of their own.
    private static func namespacesOf(_ translators: [String]) -> [(String, String)] {
        var result: [(String, String)] = []
        for entry in translators {
            let at = entry.firstIndex(of: "@")
            let klass = at.map { String(entry[..<$0]) } ?? entry
            let namespace: String?
            if let at {
                let name = String(entry[entry.index(after: at)...])
                namespace = name.hasPrefix("*") ? nil : name
            } else if klass == "script_translator" || klass == "table_translator" {
                namespace = "translator"
            } else if klass == "reverse_lookup_translator" {
                namespace = "reverse_lookup"
            } else {
                namespace = nil
            }
            guard let namespace else { continue }
            let pair = (namespace, klass == "reverse_lookup_translator" ? "reverse_lookup" : "abc")
            if !result.contains(where: { $0 == pair }) { result.append(pair) }
        }
        return result
    }

    /// The part of `pattern` every match starts with, up to its first regular-expression operator.
    private static func literalHead(_ pattern: String) -> String {
        let operators = Set("[(.*+?{\\|$")
        let body = pattern.hasPrefix("^") ? pattern.dropFirst() : Substring(pattern)
        return String(body.prefix { !operators.contains($0) })
    }

    /// The captions an `xlit` rule of the translator gives to one to five alphabet symbols: the
    /// scheme's own stroke labels. Empty when it has no such rule.
    private static func strokeCaptions(_ translator: [String: Any]?, alphabet: String) -> [SchemaKeyProfile.Stroke] {
        let known = Set(alphabet.unicodeScalars)
        for rule in stringList(translator?["preedit_format"]) {
            guard rule.hasPrefix("xlit"), rule.count >= 5 else { continue }
            let body = rule.dropFirst(4)
            guard let delimiter = body.first else { continue }
            let parts = body.dropFirst().split(separator: delimiter, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let source = Array(parts[0].unicodeScalars)
            let target = Array(parts[1].unicodeScalars)
            guard (1...maximumStrokes).contains(source.count), source.count == target.count,
                source.allSatisfy(known.contains)
            else { continue }
            return zip(source, target).map { SchemaKeyProfile.Stroke(code: String($0), label: String($1)) }
        }
        return []
    }
}
