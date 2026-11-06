// ---------------------------------------------------------------------------
// traditional-catalog-main.swift — real macOS acceptance evidence for the four
// traditional-Chinese catalogue entries (rime-bopomofo / rime-cangjie /
// rime-quick / rime-cantonese).
//
// One item per process (librime is a process singleton): the real PackageManager
// prepares the pinned archive set through prepareRecommended, installs it
// through installSchemeImport, and the deploy callback starts the real
// RimeBridge/librime engine on the staging directories so librime itself
// compiles dictionaries, tables and schemas into user/build — the exact
// directory the keyboard context reads as its prebuilt build. After the store
// commits, a fresh prebuilt engine (shared=resources, user=user,
// prebuilt=user/build) selects the advertised main schema, types a code looked
// up in the installed dictionary and must return candidates. The installed
// schema_list must be exactly the catalogue entry's advertised list (bopomofo
// advertises bopomofo_tw and bopomofo), with its main schema first.
//
// Everything printed is machine parsable (INFO/PASS/FAIL/RESULT); the JSON
// report is written to --report. The shell wrapper reports deploy log lines and
// checks each resolver warning against the deployed tree.
//
// The pinned archives are not downloaded here. Fetch the exact same files with
// songyan-android's scripts/fetch-test-schemes.sh, which writes
// <repository>-<revision>.zip into the shared .local/test-schemes directory.
//
// Usage:
//   traditional-catalog-main --item rime-bopomofo --archives <dir>
//       --root <store slot> --opencc <opencc dir> --report <json>
// ---------------------------------------------------------------------------
import CryptoKit
import Foundation
import Yams
import ZIPFoundation

@testable import PackageManager

// MARK: - Report

struct ArchiveReport: Codable {
    let id: String
    let revision: String
    let zip: String
    let expectedBytes: Int64
    let actualBytes: Int64
    let sha256: String
}

struct LicenseReport: Codable {
    let archive: String
    let path: String
    let bytes: Int
    let installedPath: String?
    let complete: Bool
}

struct ItemReport: Codable {
    var item = ""
    var mainSchema = ""
    var languageTag = ""
    var archives: [ArchiveReport] = []
    var zipBytesTotal: Int64 = 0
    var byteCountHintTotal: Int64 = 0
    var preparedSchemaIDs: [String] = []
    var manifestSchemaID = ""
    var revision = ""
    var generation = ""
    var deployNativeMilliseconds = 0.0
    var deployCallbackMilliseconds = 0.0
    var installMilliseconds = 0.0
    var enabledSchemaIDs: [String] = []
    var unavailableComponents: [String] = []
    var publishedDefaultSchemaList: [String] = []
    var compiledDefaultSchemaList: [String] = []
    var compiledSchemaFiles: [String] = []
    var buildBinaryBytes: [String: Int] = [:]
    var resourceBytes = 0
    var resourceFileCount = 0
    var dictionaryPath = ""
    var dictionaryRow = ""
    var algebraRules: [String] = []
    var typedCode = ""
    var candidateTexts: [String] = []
    var expectedTextFound = false
    var candidatesNonEmpty = false
    var licenses: [LicenseReport] = []
    var resourceRoot = ""
    var userDataRoot = ""
    var buildRoot = ""
    var failures: [String] = []
    var status = "fail"
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ kind: String, _ message: String) {
    print("\(kind): \(message)")
    fflush(stdout)
}
func info(_ message: String) { log("INFO", message) }
func passLog(_ message: String) { log("PASS", message) }
func failLog(_ message: String) { log("FAIL", message) }

// MARK: - Files

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func regularFiles(under directory: URL) -> [(path: String, url: URL, bytes: Int)] {
    var files: [(path: String, url: URL, bytes: Int)] = []
    guard
        let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
    else { return files }
    for case let url as URL in walker {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
        let path = String(url.path.dropFirst(directory.path.count + 1))
        files.append((path, url, values?.fileSize ?? 0))
    }
    return files.sorted { $0.path < $1.path }
}

// MARK: - YAML

func loadYAML(_ url: URL) throws -> [String: Any] {
    let text = try String(contentsOf: url, encoding: .utf8)
    guard let root = try Yams.load(yaml: text) as? [String: Any] else {
        throw HarnessError("YAML root is not a mapping: \(url.path)")
    }
    return root
}

func schemaList(in url: URL) throws -> [String] {
    let root = try loadYAML(url)
    let rows = root["schema_list"] as? [[String: Any]] ?? []
    return rows.compactMap { $0["schema"] as? String }
}

// MARK: - Speller algebra

/// Applies a Rime spelling-algebra list the way librime's dictionary compiler
/// does when it builds the prism: xform rewrites a syllable in place, xlit
/// transliterates characters, derive adds an extra spelling for the same
/// syllabary entry. The typed code is therefore read off the real installed
/// dictionary row plus the real installed algebra instead of being guessed.
struct Algebra {
    let rules: [String]

    func apply(to code: String) -> (primary: String, derived: [String]) {
        var primary = code
        var derived: [String] = []
        for rule in rules {
            if rule.hasPrefix("xform/"), let pieces = slashPieces(rule, dropping: "xform/".count) {
                primary = replaceAll(pattern: pieces.0, template: pieces.1, in: primary)
            } else if rule.hasPrefix("xlit|") {
                primary = transliterate(rule, primary)
            } else if rule.hasPrefix("derive/"), let pieces = slashPieces(rule, dropping: "derive/".count) {
                let extra = replaceAll(pattern: pieces.0, template: pieces.1, in: code)
                if extra != code { derived.append(extra) }
            }
        }
        return (primary, derived)
    }

    /// Splits a rule that already had its name and slash dropped from the front.
    private func slashPieces(_ rule: String, dropping count: Int) -> (String, String)? {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in rule.dropFirst(count) {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
                current.append(character)
            } else if character == "/" {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func replaceAll(pattern: String, template: String, in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private func transliterate(_ rule: String, _ text: String) -> String {
        let pieces = rule.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 3 else { return text }
        let source = Array(pieces[1])
        let target = Array(pieces[2])
        var result = ""
        for character in text {
            if let position = source.firstIndex(of: character), position < target.count {
                result.append(target[position])
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// Effective speller/algebra of a deployed schema: the compiled build config
/// when librime materialized it, else the source schema with named __patch
/// includes resolved from the same resource tree.
func effectiveAlgebra(build: URL, resources: URL, schemaID: String) throws -> [String] {
    let compiled = build.appendingPathComponent("\(schemaID).schema.yaml")
    if FileManager.default.fileExists(atPath: compiled.path),
        let root = try? loadYAML(compiled),
        let speller = root["speller"] as? [String: Any],
        let algebra = speller["algebra"] as? [String], !algebra.isEmpty
    {
        return algebra
    }
    let source = resources.appendingPathComponent("\(schemaID).schema.yaml")
    guard let root = try? loadYAML(source),
        let speller = root["speller"] as? [String: Any],
        let algebra = speller["algebra"]
    else { return [] }
    if let list = algebra as? [String] { return list }
    guard let mapping = algebra as? [String: Any], let patch = mapping["__patch"] as? [String] else { return [] }
    var rules: [String] = []
    for entry in patch {
        let pieces = entry.split(separator: ":", maxSplits: 1).map(String.init)
        let file = pieces[0] + ".yaml"
        let key = pieces.count > 1 ? String(pieces[1]).replacingOccurrences(of: "/", with: "") : ""
        guard let document = try? loadYAML(resources.appendingPathComponent(file)),
            let list = document[key] as? [String]
        else { throw HarnessError("cannot resolve algebra include \(entry) in \(file)") }
        rules.append(contentsOf: list)
    }
    return rules
}

/// The dictionary row that proves the typed code: the first row whose first
/// column is exactly the expected word, with the code column kept verbatim.
func dictionaryRow(path: URL, word: String, codeColumn: Int = 1) throws -> (row: String, code: String) {
    let stream = try String(contentsOf: path, encoding: .utf8)
    for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("#") || line.hasPrefix("---") { continue }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        if fields.count > codeColumn, fields[0] == Substring(word) {
            return (String(line), String(fields[codeColumn]))
        }
    }
    throw HarnessError("dictionary \(path.lastPathComponent) has no row for \(word)")
}

// MARK: - Item registry

struct ItemSpec {
    let id: String
    let mainSchema: String
    let dictionaryFile: String
    let expectedText: String
}

let itemSpecs: [String: ItemSpec] = [
    "rime-bopomofo": ItemSpec(
        id: "rime-bopomofo", mainSchema: "bopomofo_tw",
        dictionaryFile: "terra_pinyin.dict.yaml", expectedText: "你"),
    "rime-cangjie": ItemSpec(
        id: "rime-cangjie", mainSchema: "cangjie5",
        dictionaryFile: "cangjie5.base.dict.yaml", expectedText: "你"),
    "rime-quick": ItemSpec(
        id: "rime-quick", mainSchema: "quick5",
        dictionaryFile: "cangjie5.base.dict.yaml", expectedText: "你"),
    "rime-cantonese": ItemSpec(
        id: "rime-cantonese", mainSchema: "jyut6ping3",
        dictionaryFile: "jyut6ping3.chars.dict.yaml", expectedText: "你"),
]

final class DeploymentEvidence: @unchecked Sendable {
    var nativeMilliseconds = 0.0
    var callbackMilliseconds = 0.0
    var enabledSchemaIDs: [String] = []
    var unavailableComponents: [String] = []
}

// MARK: - Run

func runHarness() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var options: [String: String] = [:]
    var index = 0
    while index + 1 < arguments.count {
        let key = arguments[index]
        guard key.hasPrefix("--") else { break }
        options[String(key.dropFirst(2))] = arguments[index + 1]
        index += 2
    }
    guard let itemID = options["item"], let archivesDirectory = options["archives"],
        let rootPath = options["root"], let openCCPath = options["opencc"],
        let reportPath = options["report"]
    else {
        FileHandle.standardError.write(
            Data(
                "usage: traditional-catalog-main --item <id> --archives <dir> --root <slot> --opencc <dir> --report <json>\n"
                    .utf8))
        exit(64)
    }
    guard let spec = itemSpecs[itemID] else {
        FileHandle.standardError.write(Data("unknown item \(itemID)\n".utf8))
        exit(64)
    }
    guard let catalogueEntry = RecommendedSchemeSource.catalog.first(where: { $0.id == spec.id }) else {
        FileHandle.standardError.write(
            Data("catalogue entry \(spec.id) is missing from RecommendedSchemeSource.catalog\n".utf8))
        exit(1)
    }
    // The shipped entry is used unchanged: the strict SHA check, the complete archive closure and
    // the real store transaction are exactly what a user gets from the catalogue.
    let source = catalogueEntry

    let rootURL = URL(fileURLWithPath: rootPath)
    let archivesURL = URL(fileURLWithPath: archivesDirectory)
    let openCCURL = URL(fileURLWithPath: openCCPath)
    let reportURL = URL(fileURLWithPath: reportPath)

    var report = ItemReport()
    report.item = spec.id
    report.mainSchema = spec.mainSchema
    report.languageTag = source.languageTag

    do {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let manager = RecipePackageManager(rootURL: rootURL, sharedOpenCCDirectory: openCCURL)

        // MARK: Pinned archives (same order as the catalogue entry)
        var archiveURLs: [URL] = []
        for archive in source.archives {
            let revision = archive.url.lastPathComponent
            let file = archivesURL.appendingPathComponent("\(archive.id)-\(revision).zip")
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw HarnessError("missing pinned archive \(file.path)")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            report.archives.append(
                ArchiveReport(
                    id: archive.id, revision: revision, zip: file.lastPathComponent,
                    expectedBytes: archive.byteCountHint, actualBytes: bytes, sha256: archive.sha256))
            report.zipBytesTotal += bytes
            report.byteCountHintTotal += archive.byteCountHint
            archiveURLs.append(file)
        }
        info(
            "archives \(report.archives.count), actual zip bytes \(report.zipBytesTotal), hint \(report.byteCountHintTotal)"
        )

        // MARK: prepareRecommended (real, strict SHA)
        let prepared = try manager.prepareRecommended(source, archiveURLs: archiveURLs)
        report.preparedSchemaIDs = prepared.schemaIDs
        report.manifestSchemaID = prepared.manifest.schemaID
        report.revision = prepared.manifest.revision
        info(
            "prepared: schemas \(prepared.schemaIDs.joined(separator: ",")), entry \(prepared.manifest.schemaID), revision \(prepared.manifest.revision)"
        )

        let advertised = source.advertisedSchemaIDs ?? []
        if advertised != prepared.schemaIDs {
            report.failures.append("prepared schema set \(prepared.schemaIDs) != advertised \(advertised)")
        }
        if prepared.manifest.schemaID != spec.mainSchema {
            report.failures.append("entry schema \(prepared.manifest.schemaID) != \(spec.mainSchema)")
        }
        // The frontend-owned default.yaml is generated after the source snapshot, so the exact bytes
        // that will be installed come from preparedBytes, not from the raw upstream snapshot.
        if let defaultData = prepared.preparedBytes(for: "default.yaml"),
            let root = try? Yams.load(yaml: String(decoding: defaultData, as: UTF8.self)) as? [String: Any],
            let rows = root["schema_list"] as? [[String: Any]]
        {
            let listed = rows.compactMap { $0["schema"] as? String }
            // The entry's whole advertised list is published, with the default input method first.
            if listed != advertised || listed.first != spec.mainSchema {
                report.failures.append(
                    "prepared default.yaml publishes \(listed), expected \(advertised) with \(spec.mainSchema) first")
            }
        } else {
            report.failures.append("prepared source has no readable default.yaml")
        }

        // MARK: Real native deploy callback
        let evidence = DeploymentEvidence()
        let deploy: RecipePackageManager.Deploy = { deployment in
            let callbackStart = Date()
            let engine = RimeEngine(
                configuration: .init(
                    sharedDirectory: deployment.resourceURL, userDirectory: deployment.userDataURL))
            defer { engine.shutdown() }
            let nativeStart = Date()
            try engine.start()
            evidence.nativeMilliseconds = Date().timeIntervalSince(nativeStart) * 1000
            let enabled = engine.schemas().map(\.id)
            evidence.enabledSchemaIDs = enabled
            guard !enabled.isEmpty else {
                throw HarnessError("engine deployed no enabled schema under \(deployment.resourceURL.path)")
            }
            let entry = try deployment.declaredEntry(in: enabled)
            if entry != spec.mainSchema {
                throw HarnessError("deployed entry \(entry) != \(spec.mainSchema)")
            }
            try engine.prepareSchemaDependencyClosure(schemaIDs: enabled)
            var missing: [String] = []
            for schemaID in enabled {
                try engine.validateSchemaForActivation(schemaID: schemaID)
                missing.append(contentsOf: engine.unavailableComponents(schemaID: schemaID))
            }
            if !missing.isEmpty {
                throw HarnessError("runtime components unavailable: \(missing.joined(separator: ","))")
            }
            evidence.unavailableComponents = missing
            evidence.callbackMilliseconds = Date().timeIntervalSince(callbackStart) * 1000
            info(
                "native deploy \(String(format: "%.1f", evidence.nativeMilliseconds)) ms, callback \(String(format: "%.1f", evidence.callbackMilliseconds)) ms, enabled \(enabled.joined(separator: ","))"
            )
            return RecipeDeploymentReceipt(
                availableComponents: [], validatedSchemaID: entry, validatedEnabledSchemaIDs: enabled)
        }

        // MARK: installSchemeImport (real store transaction)
        let installStart = Date()
        let installed = try await manager.installSchemeImport(prepared, deploy: deploy)
        report.installMilliseconds = Date().timeIntervalSince(installStart) * 1000
        report.generation = installed.generation
        report.deployNativeMilliseconds = evidence.nativeMilliseconds
        report.deployCallbackMilliseconds = evidence.callbackMilliseconds
        report.enabledSchemaIDs = evidence.enabledSchemaIDs
        report.unavailableComponents = evidence.unavailableComponents
        guard let active = try await manager.activeInstallation() else {
            throw HarnessError("store has no active installation after a successful install")
        }
        if active.installation.generation != installed.generation {
            report.failures.append(
                "active generation \(active.installation.generation) != installed \(installed.generation)")
        }
        let resources = active.resourceURL
        let userData = active.userDataURL
        let build = userData.appendingPathComponent(InstalledPackageLayout.buildDirectory)
        // Recorded in the report so the wrapper can tell a deploy-time "not compiled yet" resolver
        // warning from a path that really is missing after the deploy.
        report.resourceRoot = resources.path
        report.userDataRoot = userData.path
        report.buildRoot = build.path

        // MARK: Published / compiled configuration
        report.publishedDefaultSchemaList = try schemaList(in: resources.appendingPathComponent("default.yaml"))
        report.compiledDefaultSchemaList = try schemaList(in: build.appendingPathComponent("default.yaml"))
        if report.publishedDefaultSchemaList != advertised || report.publishedDefaultSchemaList.first != spec.mainSchema
        {
            report.failures.append(
                "published default.yaml lists \(report.publishedDefaultSchemaList), expected \(advertised)")
        }
        if report.compiledDefaultSchemaList != advertised {
            report.failures.append(
                "compiled default.yaml lists \(report.compiledDefaultSchemaList), expected \(advertised)")
        }

        let buildFiles = regularFiles(under: build)
        report.compiledSchemaFiles = buildFiles.map(\.path).filter { $0.hasSuffix(".schema.yaml") }.sorted()
        for schemaID in report.enabledSchemaIDs {
            let compiled = build.appendingPathComponent(InstalledPackageLayout.schemaFile(schemaID))
            if !FileManager.default.fileExists(atPath: compiled.path) {
                report.failures.append("compiled schema missing: build/\(InstalledPackageLayout.schemaFile(schemaID))")
            }
        }
        let binaries = buildFiles.filter { $0.path.hasSuffix(".bin") }
        report.buildBinaryBytes = Dictionary(uniqueKeysWithValues: binaries.map { ($0.path, $0.bytes) })
        if binaries.isEmpty {
            report.failures.append("native deploy produced no .bin artifacts under user/build")
        }
        info(
            "build: \(report.compiledSchemaFiles.count) compiled schemas, \(binaries.count) .bin files, \(binaries.reduce(0) { $0 + $1.bytes }) bytes"
        )

        let resourceFiles = regularFiles(under: resources)
        report.resourceFileCount = resourceFiles.count
        report.resourceBytes = resourceFiles.reduce(0) { $0 + $1.bytes }

        // MARK: Complete licences / notices from every upstream archive
        do {
            var installedHashes: [String: String] = [:]
            for file in resourceFiles {
                installedHashes[sha256(try Data(contentsOf: file.url))] = file.path
            }
            let licenceName = try NSRegularExpression(
                pattern: "^(LICENSE|LICENCE|NOTICE|COPYING|AUTHORS|PROVENANCE|README)([-.].*)?$",
                options: [.caseInsensitive])
            for archive in source.archives {
                let url = archivesURL.appendingPathComponent("\(archive.id)-\(archive.url.lastPathComponent).zip")
                let zip = try Archive(url: url, accessMode: .read)
                for entry in zip where entry.type == .file {
                    let name = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
                    let range = NSRange(name.startIndex..<name.endIndex, in: name)
                    guard licenceName.firstMatch(in: name, range: range) != nil else { continue }
                    var bytes = Data()
                    _ = try zip.extract(entry) { chunk in bytes.append(chunk) }
                    let digest = sha256(bytes)
                    report.licenses.append(
                        LicenseReport(
                            archive: archive.id, path: entry.path, bytes: bytes.count,
                            installedPath: installedHashes[digest], complete: installedHashes[digest] != nil))
                }
            }
            let missing = report.licenses.filter { !$0.complete }
            if !missing.isEmpty {
                report.failures.append(
                    "licence/notice files not installed byte-identically: \(missing.map { $0.archive + ":" + $0.path })"
                )
            }
            info("licences/notices: \(report.licenses.count) files, \(missing.count) missing")
        }

        // MARK: Dictionary code derivation
        let dictionaryURL = resources.appendingPathComponent(spec.dictionaryFile)
        guard FileManager.default.fileExists(atPath: dictionaryURL.path) else {
            throw HarnessError("installed dictionary missing: \(spec.dictionaryFile)")
        }
        report.dictionaryPath = spec.dictionaryFile
        let row = try dictionaryRow(path: dictionaryURL, word: spec.expectedText)
        report.dictionaryRow = row.row
        let algebraRules = try effectiveAlgebra(build: build, resources: resources, schemaID: spec.mainSchema)
        report.algebraRules = algebraRules
        let spelling = Algebra(rules: algebraRules).apply(to: row.code)
        let typedCode = spelling.derived.first ?? spelling.primary
        report.typedCode = typedCode
        info(
            "dict row \(spec.dictionaryFile): \(row.row) | algebra rules \(algebraRules.count) | typed \(typedCode)")

        // MARK: Fresh prebuilt engine -> candidates
        let candidateEngine = RimeEngine(
            configuration: .init(
                sharedDirectory: resources, userDirectory: userData, prebuiltDirectory: build))
        defer { candidateEngine.shutdown() }
        try candidateEngine.start()
        if candidateEngine.currentSchemaID != spec.mainSchema {
            guard candidateEngine.selectSchema(spec.mainSchema) else {
                throw HarnessError("cannot select \(spec.mainSchema) on the prebuilt engine")
            }
        }
        candidateEngine.clearComposition()
        for character in typedCode {
            guard let key = RimeKey(character: character) else {
                throw HarnessError("code \(typedCode) contains a non-printable key")
            }
            _ = try candidateEngine.processKey(key)
        }
        var state = candidateEngine.state()
        var pages = 0
        var matched = state.candidates.contains(where: { $0.text == spec.expectedText })
        while !matched, !state.isLastPage, pages < 20 {
            if let next = candidateEngine.pageForward() {
                state = next
            } else {
                break
            }
            matched = state.candidates.contains(where: { $0.text == spec.expectedText })
            pages += 1
        }
        if pages > 0 {
            _ = candidateEngine.pageBackward()
            state = candidateEngine.state()
        }
        report.candidateTexts = state.candidates.prefix(10).map(\.text)
        report.candidatesNonEmpty = !state.candidates.isEmpty
        report.expectedTextFound = matched
        if !report.candidatesNonEmpty {
            report.failures.append("typing \(typedCode) produced no candidates for \(spec.mainSchema)")
        }
        info(
            "prebuilt engine typed \(typedCode): \(state.candidates.count) candidates, first \(report.candidateTexts.joined(separator: "/"))"
        )
    } catch {
        report.failures.append(String(describing: error))
    }

    report.status = report.failures.isEmpty ? "pass" : "fail"
    for failure in report.failures { failLog(failure) }
    if report.status == "pass" {
        passLog(
            "\(report.item): \(report.mainSchema) installed, native deploy \(String(format: "%.1f", report.deployNativeMilliseconds)) ms, candidates \(report.candidateTexts.joined(separator: "/"))"
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        try encoder.encode(report).write(to: reportURL, options: .atomic)
    } catch {
        failLog("cannot write report \(reportURL.path): \(error)")
    }
    print("RESULT: \(report.status)")
    if report.status != "pass" { exit(1) }
}

@main
struct TraditionalCatalogHarness {
    static func main() async {
        await runHarness()
    }
}
