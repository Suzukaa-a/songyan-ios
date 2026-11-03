import Foundation
import Yams

/// The backstop behind the checks on the user's files: after librime compiled a generation, every
/// file-naming value in the compiled build files is checked at its real place, whatever patch spelling
/// produced it. A value that is absolute, climbs out with `..`, or is otherwise not a plain relative name
/// fails the install, so librime never opens it when the keyboard runs. Every Lua component a compiled
/// schema mounts must also be one its own sources name: shipped by the package in the file that compiles
/// into it (or one that file includes), or confirmed by the user for that file of that package.
enum CompiledConfigGuard {
    private static let maximumBytes = 32 * 1024 * 1024

    /// Throws `UserConfigError` naming the compiled file at fault. A Lua component the compiled files
    /// name must be one `scope` allows in that file: a patch can assemble an entry from pieces no check on
    /// the files reads whole, and a name that is fine in one file is not thereby fine in another.
    static func check(build: URL, scope: ScriptScope = ScriptScope()) throws {
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? [])
            .filter { $0.hasSuffix(".yaml") }.sorted()
        for name in names {
            try Task.checkCancellation()
            let url = build.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            guard (values?.fileSize ?? 0) <= maximumBytes else { throw UserConfigError(name, .tooLarge) }
            guard let text = UserConfigFiles.decode(try Data(contentsOf: url)) else {
                throw UserConfigError(name, .notText)
            }
            let result = UserConfigFiles.read(name, text)
            if let error = result.error { throw error }
            if let bad = UserConfigSafety.unsafeReference(result.root) {
                throw UserConfigError(name, .unsafeReference, detail: String(bad.prefix(80)))
            }
            let allowed = scope.allowed(compiled: name)
            if let unknown = UserConfigSafety.luaComponents(result.root).first(where: { !allowed.contains($0) }) {
                throw UserConfigError(name, .unconfirmedScript, detail: String(unknown.prefix(80)))
            }
        }
    }

    /// What the package's own YAML files name, by file. Files too large to read count for nothing, which
    /// can only make the comparison stricter.
    static func shippedScope(resources: URL) -> ScriptScope {
        var scope = ScriptScope()
        func scan(_ directory: URL, _ prefix: String) {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            let children =
                (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            for child in children {
                let name = child.lastPathComponent
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true,
                    !(prefix.isEmpty && name == InstalledPackageLayout.buildDirectory)
                else { continue }
                if values.isDirectory == true {
                    scan(child, prefix + name + "/")
                } else if values.isRegularFile == true, name.hasSuffix(".yaml"),
                    (values.fileSize ?? 0) <= UserConfigFiles.maximumFileBytes * 2,
                    let data = try? Data(contentsOf: child)
                {
                    scope.add(prefix + name, data, allowing: nil)
                }
            }
        }
        scan(resources, "")
        return scope
    }
}

/// Which Lua components a compiled file may name. A component is allowed in a compiled file when the
/// source file that compiles into it (`x.schema.yaml`, `x.yaml`, or the user's `x.custom.yaml`), or a file
/// those include or patch from, ships it or has it confirmed; the same text elsewhere in the package does not count.
struct ScriptScope {
    /// Source path to the components allowed there.
    private(set) var components: [String: Set<String>] = [:]
    /// Source path to the files its includes and patches name.
    private(set) var references: [String: Set<String>] = [:]

    /// Records the file's references and its components: all of them when `confirmed` is nil (the
    /// package's own file), otherwise only those the user confirmed for this file.
    mutating func add(_ path: String, _ data: Data, allowing confirmed: Set<String>?) {
        guard let text = UserConfigFiles.decode(data) else { return }
        let result = UserConfigFiles.read(path, text)
        guard result.error == nil else { return }
        references[path, default: []].formUnion(UserConfigSafety.fileReferences(result.root))
        let named = Set(UserConfigSafety.luaComponents(result.root))
        components[path, default: []].formUnion(confirmed.map { named.intersection($0) } ?? named)
    }

    /// The user's files of one install, with what they confirmed for each.
    mutating func add(_ plan: RimeConfigFolder.Plan, confirmed: [String: Set<String>]) {
        for file in plan.files where file.path.hasSuffix(".yaml") {
            add(file.path, file.data, allowing: confirmed[file.path] ?? [])
        }
    }

    /// Companions inherit the source's shipped and confirmed components, just as their generated YAML does.
    mutating func inherit(generated: String, source: String) {
        references[generated + ".schema.yaml", default: []].formUnion([
            source + ".schema.yaml", source + ".custom.yaml",
        ])
    }

    func allowed(compiled name: String) -> Set<String> {
        var pending = [name]
        if name.hasSuffix(".yaml") {
            let stem =
                name.hasSuffix(".schema.yaml") ? name.dropLast(".schema.yaml".count) : name.dropLast(".yaml".count)
            pending.append(stem + ".custom.yaml")
        }
        var seen = Set<String>()
        var found = Set<String>()
        while let path = pending.popLast() {
            guard seen.insert(path).inserted else { continue }
            found.formUnion(components[path] ?? [])
            pending.append(contentsOf: references[path] ?? [])
        }
        return found
    }
}
