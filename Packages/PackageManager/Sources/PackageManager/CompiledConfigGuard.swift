import Foundation
import Yams

/// The backstop behind the checks on the user's files: after librime compiled a generation, every
/// file-naming value in the compiled build files is checked at its real place, whatever patch spelling
/// produced it. A value that is absolute, climbs out with `..`, or is otherwise not a plain relative name
/// fails the install, so librime never opens it when the keyboard runs. Every Lua component a compiled
/// schema mounts must also be one the sources name: shipped by the package or the app's own files, or
/// covered by a script the user confirmed.
enum CompiledConfigGuard {
    private static let maximumBytes = 32 * 1024 * 1024

    /// Throws `UserConfigError` naming the compiled file at fault. A Lua component the compiled files
    /// name must be one the package ships (`shipped`) or one the user agreed to (`confirmed`): a patch can
    /// assemble an entry from pieces no check on the files reads whole.
    static func check(build: URL, shipped: Set<String> = [], confirmed: Set<String> = []) throws {
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
            if let unknown = UserConfigSafety.luaComponents(result.root).first(where: {
                !shipped.contains($0) && !confirmed.contains($0)
            }) {
                throw UserConfigError(name, .unconfirmedScript, detail: String(unknown.prefix(80)))
            }
        }
    }

    /// Every Lua component the package's own YAML files name (dictionary headers included). Files too
    /// large to read count for nothing, which can only make the comparison stricter.
    static func shippedComponents(resources: URL) -> Set<String> {
        var found = Set<String>()
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
                    found.formUnion(UserScripts.components(prefix + name, data))
                }
            }
        }
        scan(resources, "")
        return found
    }
}
