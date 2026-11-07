import Darwin
import Foundation

// The host installs a package whose compiled bins already exist under the read-only
// installation `resources/build`; deployment still writes its own build under the writable
// `user/build`. A publication may only hardlink bytes that already live in a read-only tree,
// and only after proving the current work bytes are identical:
//  * two published generations of one unchanged bin share one inode with the installed source
//    (or with the previous published generation when the package carries no prebuilt build);
//  * the writable deployment work is never an inode source, so later work writes cannot change
//    a committed generation;
//  * same-length different content keeps the current work bytes;
//  * compiled YAML and learning databases are always copied;
//  * the whole publication root stays within 1.3x one compiled build after inode dedupe.

private let prebuiltSchemaID = "kagiroi"
private let prebuiltBinNames = ["kagiroi.table.bin", "kagiroi.reverse.bin", "kagiroi.prism.bin"]
private let prebuiltBinSize = 1024 * 1024

private struct PrebuiltPublicationFixture {
    let root: URL
    let resources: URL
    let work: URL
}

private func prebuiltCheck(_ condition: Bool, _ message: String) {
    precondition(condition, "CHECK FAILED: " + message)
}

private func prebuiltDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func prebuiltWrite(_ url: URL, _ data: Data) throws {
    try prebuiltDirectory(url.deletingLastPathComponent())
    try data.write(to: url, options: .atomic)
}

private func prebuiltBytes(_ count: Int, seed: UInt8) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { raw in
        for index in 0..<count {
            raw[index] = seed &+ UInt8(truncatingIfNeeded: index &* 31)
        }
    }
    return data
}

private func prebuiltIdentity(_ url: URL) throws -> (device: dev_t, inode: ino_t) {
    var info = stat()
    let status = url.path.withCString { stat($0, &info) }
    guard status == 0 else {
        throw NSError(
            domain: "prebuilt-publication-sharing", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "cannot stat \(url.path)"])
    }
    return (info.st_dev, info.st_ino)
}

private func prebuiltSharesStorage(_ first: URL, _ second: URL) throws -> Bool {
    let left = try prebuiltIdentity(first)
    let right = try prebuiltIdentity(second)
    return left.device == right.device && left.inode == right.inode
}

private func prebuiltFileBytes(_ url: URL) throws -> Int {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return values.fileSize ?? 0
}

/// Logical bytes and inode-deduplicated bytes, the identity the 1.3x budget is defined on.
private func prebuiltStorage(_ directory: URL) throws -> (logical: Int, unique: Int) {
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { return (0, 0) }
    var logical = 0
    var unique = 0
    var seen = Set<String>()
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let identity = try prebuiltIdentity(url)
        let size = try prebuiltFileBytes(url)
        logical += size
        if seen.insert("\(identity.device):\(identity.inode)").inserted { unique += size }
    }
    return (logical, unique)
}

private func prebuiltGeneration(_ root: URL) throws -> URL {
    guard let activation = try KeyboardRecipeStore.activation(rootURL: root) else {
        throw NSError(
            domain: "prebuilt-publication-sharing", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "publication did not commit an active record"])
    }
    return root.appendingPathComponent("versions").appendingPathComponent(activation.generation)
}

/// `installedSourceBuild` models a package compiled on a machine: its bins are installed as
/// read-only `resources/build` and the deployment work duplicates the same bytes.
private func makePrebuiltFixture(_ base: URL, installedSourceBuild: Bool) throws -> PrebuiltPublicationFixture {
    let fixture = PrebuiltPublicationFixture(
        root: base.appendingPathComponent("published", isDirectory: true),
        resources: base.appendingPathComponent("installed").appendingPathComponent("resources", isDirectory: true),
        work: base.appendingPathComponent("installed").appendingPathComponent("user")
            .appendingPathComponent("build", isDirectory: true))
    try prebuiltDirectory(fixture.root)
    try prebuiltDirectory(fixture.resources)
    try prebuiltDirectory(fixture.work)
    let defaultYAML = Data("schema_list:\n  - schema: \(prebuiltSchemaID)\n".utf8)
    let schemaYAML = Data("schema:\n  name: \(prebuiltSchemaID)\n".utf8)
    try prebuiltWrite(fixture.resources.appendingPathComponent("default.yaml"), defaultYAML)
    try prebuiltWrite(fixture.resources.appendingPathComponent(prebuiltSchemaID + ".schema.yaml"), schemaYAML)
    try prebuiltWrite(fixture.work.appendingPathComponent("default.yaml"), defaultYAML)
    try prebuiltWrite(fixture.work.appendingPathComponent(prebuiltSchemaID + ".schema.yaml"), schemaYAML)
    for (index, name) in prebuiltBinNames.enumerated() {
        try prebuiltWrite(
            fixture.work.appendingPathComponent(name),
            prebuiltBytes(prebuiltBinSize, seed: UInt8(17 + index)))
    }
    if installedSourceBuild {
        let installedBuild = fixture.resources.appendingPathComponent("build", isDirectory: true)
        try prebuiltWrite(installedBuild.appendingPathComponent("default.yaml"), defaultYAML)
        try prebuiltWrite(installedBuild.appendingPathComponent(prebuiltSchemaID + ".schema.yaml"), schemaYAML)
        for (index, name) in prebuiltBinNames.enumerated() {
            try prebuiltWrite(
                installedBuild.appendingPathComponent(name),
                prebuiltBytes(prebuiltBinSize, seed: UInt8(17 + index)))
        }
    }
    return fixture
}

private func publishPrebuilt(_ fixture: PrebuiltPublicationFixture, revision: String) throws {
    try KeyboardRecipeStore.publish(
        resources: fixture.resources, compiledBuild: fixture.work, revision: revision,
        rootURL: fixture.root, kind: .userScheme, packageID: "kagiroi-prebuilt",
        schemas: [
            KeyboardSchemaDescriptor(
                id: prebuiltSchemaID, name: prebuiltSchemaID, alphabet: "abcdefghijklmnopqrstuvwxyz")
        ],
        selectedSchemaID: prebuiltSchemaID, layout: .qwerty26,
        publishedKeyboards: [PublishedKeyboard(schemaID: prebuiltSchemaID, layout: .qwerty26)])
}

// MARK: - Scenarios

/// A prebuilt package's three bin kinds must be linked from the installed read-only source by
/// every generation, and never from the writable deployment work.
private func sharedSourceBins(_ base: URL) throws {
    let fixture = try makePrebuiltFixture(base, installedSourceBuild: true)
    try publishPrebuilt(fixture, revision: "first")
    let first = try prebuiltGeneration(fixture.root)
    try publishPrebuilt(fixture, revision: "second")
    let second = try prebuiltGeneration(fixture.root)
    prebuiltCheck(first.path != second.path, "the second publication commits a new generation")
    prebuiltCheck(
        FileManager.default.fileExists(atPath: first.path),
        "the previous generation stays on disk while a keyboard may still be bound to it")
    for name in prebuiltBinNames {
        let installedBin = fixture.resources.appendingPathComponent("build").appendingPathComponent(name)
        let workBin = fixture.work.appendingPathComponent(name)
        let firstBin = first.appendingPathComponent("resources").appendingPathComponent("build")
            .appendingPathComponent(name)
        let secondBin = second.appendingPathComponent("resources").appendingPathComponent("build")
            .appendingPathComponent(name)
        prebuiltCheck(
            try prebuiltSharesStorage(firstBin, installedBin),
            "\(name): the first generation hardlinks the installed read-only bin")
        prebuiltCheck(
            try prebuiltSharesStorage(secondBin, installedBin),
            "\(name): the second generation hardlinks the same installed bin")
        prebuiltCheck(
            try prebuiltSharesStorage(firstBin, secondBin),
            "\(name): both generations share one inode")
        prebuiltCheck(
            try !prebuiltSharesStorage(firstBin, workBin),
            "\(name): the publication must not link the writable deployment work")
        prebuiltCheck(
            try !prebuiltSharesStorage(secondBin, workBin),
            "\(name): the second publication must not link the writable deployment work")
        let published = try Data(contentsOf: firstBin)
        let installed = try Data(contentsOf: installedBin)
        prebuiltCheck(published == installed, "\(name): published bytes equal the installed source bin")
    }
}

/// Same length but different content is still different: the stale installed bin must not win.
private func divergentSameLength(_ base: URL) throws {
    let fixture = try makePrebuiltFixture(base, installedSourceBuild: true)
    let replacements = prebuiltBinNames.map { _ in prebuiltBytes(prebuiltBinSize, seed: 0xC3) }
    for (index, name) in prebuiltBinNames.enumerated() {
        try prebuiltWrite(fixture.work.appendingPathComponent(name), replacements[index])
    }
    try publishPrebuilt(fixture, revision: "divergent")
    let generation = try prebuiltGeneration(fixture.root)
    for (index, name) in prebuiltBinNames.enumerated() {
        let installedBin = fixture.resources.appendingPathComponent("build").appendingPathComponent(name)
        let workBin = fixture.work.appendingPathComponent(name)
        let publishedBin = generation.appendingPathComponent("resources").appendingPathComponent("build")
            .appendingPathComponent(name)
        let published = try Data(contentsOf: publishedBin)
        let work = try Data(contentsOf: workBin)
        prebuiltCheck(
            published.count == work.count && published == work,
            "\(name): same-length different content keeps the deployment work bytes")
        prebuiltCheck(
            try !prebuiltSharesStorage(publishedBin, installedBin),
            "\(name): a stale installed bin is not linked when the work bytes differ")
        prebuiltCheck(
            try !prebuiltSharesStorage(publishedBin, workBin),
            "\(name): the writable deployment work is never an inode source")
        prebuiltCheck(published == replacements[index], "\(name): the replacement bytes are published verbatim")
    }
}

/// Publishing must snapshot bytes: a deploy that rewrites its work afterwards cannot reach a
/// committed generation.
private func workWriteAfterPublish(_ base: URL) throws {
    let fixture = try makePrebuiltFixture(base, installedSourceBuild: true)
    try publishPrebuilt(fixture, revision: "before")
    let first = try prebuiltGeneration(fixture.root)
    var committed: [(name: String, bytes: Data, identity: (device: dev_t, inode: ino_t))] = []
    for name in prebuiltBinNames {
        let publishedBin = first.appendingPathComponent("resources").appendingPathComponent("build")
            .appendingPathComponent(name)
        let bytes = try Data(contentsOf: publishedBin)
        committed.append((name, bytes, try prebuiltIdentity(publishedBin)))
        var rewritten = bytes
        rewritten[0] = rewritten[0] ^ 0xFF
        try prebuiltWrite(fixture.work.appendingPathComponent(name), rewritten)
    }
    for entry in committed {
        let publishedBin = first.appendingPathComponent("resources").appendingPathComponent("build")
            .appendingPathComponent(entry.name)
        let current = try Data(contentsOf: publishedBin)
        prebuiltCheck(
            current == entry.bytes,
            "\(entry.name): a later work write does not change the committed generation")
        let identity = try prebuiltIdentity(publishedBin)
        prebuiltCheck(
            identity.device == entry.identity.device && identity.inode == entry.identity.inode,
            "\(entry.name): the committed generation keeps its inode after the work changes")
    }
    try publishPrebuilt(fixture, revision: "after")
    for entry in committed {
        let publishedBin = first.appendingPathComponent("resources").appendingPathComponent("build")
            .appendingPathComponent(entry.name)
        let current = try Data(contentsOf: publishedBin)
        prebuiltCheck(
            current == entry.bytes,
            "\(entry.name): a later publication does not rewrite the first generation")
    }
}

/// Compiled YAML and learning databases are mutable bytes: always copied, never shared.
private func yamlAndUserDatabaseAreCopied(_ base: URL) throws {
    let fixture = try makePrebuiltFixture(base, installedSourceBuild: true)
    let workDatabase = fixture.work.appendingPathComponent("kagiroi.userdb").appendingPathComponent("000003.log")
    try prebuiltWrite(workDatabase, Data("learning".utf8))
    try publishPrebuilt(fixture, revision: "copy-only")
    let generation = try prebuiltGeneration(fixture.root)
    for name in ["default.yaml", prebuiltSchemaID + ".schema.yaml"] {
        let publishedYAML = generation.appendingPathComponent("resources").appendingPathComponent("build")
            .appendingPathComponent(name)
        let workYAML = fixture.work.appendingPathComponent(name)
        let installedYAML = fixture.resources.appendingPathComponent("build").appendingPathComponent(name)
        let published = try Data(contentsOf: publishedYAML)
        let work = try Data(contentsOf: workYAML)
        prebuiltCheck(published == work, "\(name): the compiled YAML keeps the current work bytes")
        prebuiltCheck(
            try !prebuiltSharesStorage(publishedYAML, workYAML),
            "\(name): compiled YAML is copied, not linked to the writable work")
        prebuiltCheck(
            try !prebuiltSharesStorage(publishedYAML, installedYAML),
            "\(name): compiled YAML is not shared with the installed source")
    }
    let publishedSourceYAML = generation.appendingPathComponent("resources")
        .appendingPathComponent(prebuiltSchemaID + ".schema.yaml")
    let installedSourceYAML = fixture.resources.appendingPathComponent(prebuiltSchemaID + ".schema.yaml")
    prebuiltCheck(
        try !prebuiltSharesStorage(publishedSourceYAML, installedSourceYAML),
        "source YAML is copied, not shared with the installed source")
    let publishedDatabase = generation.appendingPathComponent("resources").appendingPathComponent("build")
        .appendingPathComponent("kagiroi.userdb").appendingPathComponent("000003.log")
    prebuiltCheck(
        FileManager.default.fileExists(atPath: publishedDatabase.path),
        "learning database bytes travel with the publication")
    let published = try Data(contentsOf: publishedDatabase)
    let work = try Data(contentsOf: workDatabase)
    prebuiltCheck(published == work, "learning database bytes keep the work content")
    prebuiltCheck(
        try !prebuiltSharesStorage(publishedDatabase, workDatabase),
        "learning databases are copied, never linked to writable work")
}

/// Without an installed prebuilt build the only read-only tree is the previous publication, so
/// the second generation must link it instead of copying the same work bytes again.
private func previousGenerationBins(_ base: URL) throws {
    let fixture = try makePrebuiltFixture(base, installedSourceBuild: false)
    try publishPrebuilt(fixture, revision: "first")
    let first = try prebuiltGeneration(fixture.root)
    try publishPrebuilt(fixture, revision: "second")
    let second = try prebuiltGeneration(fixture.root)
    prebuiltCheck(first.path != second.path, "the second publication commits a new generation")
    for name in prebuiltBinNames {
        let firstBin = first.appendingPathComponent("resources").appendingPathComponent("build")
            .appendingPathComponent(name)
        let secondBin = second.appendingPathComponent("resources").appendingPathComponent("build")
            .appendingPathComponent(name)
        let workBin = fixture.work.appendingPathComponent(name)
        prebuiltCheck(
            try prebuiltSharesStorage(firstBin, secondBin),
            "\(name): the second generation links the previous read-only publication bin")
        prebuiltCheck(
            try !prebuiltSharesStorage(firstBin, workBin),
            "\(name): the first generation copies the work bytes and never links them")
        prebuiltCheck(
            try !prebuiltSharesStorage(secondBin, workBin),
            "\(name): the second generation never links writable work")
        let firstBytes = try Data(contentsOf: firstBin)
        let secondBytes = try Data(contentsOf: secondBin)
        prebuiltCheck(firstBytes == secondBytes, "\(name): both generations hold the same bytes")
        let workBytes = try Data(contentsOf: workBin)
        prebuiltCheck(firstBytes == workBytes, "\(name): the shared bytes are the current work bytes")
    }
}

/// The 1.3x budget: inode-unique bytes of the whole publication root over one compiled build.
private func footprintBudget(_ base: URL) throws {
    let fixture = try makePrebuiltFixture(base, installedSourceBuild: true)
    try publishPrebuilt(fixture, revision: "first")
    try publishPrebuilt(fixture, revision: "second")
    let usage = try prebuiltStorage(fixture.root)
    let compiled = try prebuiltStorage(fixture.work).logical
    prebuiltCheck(compiled > 0, "the fixture has compiled build bytes")
    prebuiltCheck(
        usage.logical > usage.unique,
        "the two published generations share storage instead of copying every byte")
    // 1.3x in integer form so the comparison is exact.
    prebuiltCheck(
        usage.unique * 10 <= compiled * 13,
        "unique publication bytes stay within 1.3x one compiled build (unique=\(usage.unique), compiled=\(compiled))")
}

func prebuiltPublicationSharingChecks(_ base: URL, scenario: String) throws {
    switch scenario {
    case "shared-source-bins": try sharedSourceBins(base)
    case "divergent-same-length": try divergentSameLength(base)
    case "work-write-after-publish": try workWriteAfterPublish(base)
    case "not-shared-yaml-userdb": try yamlAndUserDatabaseAreCopied(base)
    case "previous-generation-bins": try previousGenerationBins(base)
    case "ratio": try footprintBudget(base)
    default: fatalError("unknown prebuilt publication sharing scenario: \(scenario)")
    }
    print("PASS: prebuilt publication sharing — \(scenario)")
}
