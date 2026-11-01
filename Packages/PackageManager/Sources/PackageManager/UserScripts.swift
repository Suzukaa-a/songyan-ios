import Foundation

/// Scripts the user's files bring in, and which of them the user has agreed to use. A Lua script runs
/// inside the keyboard and reads what is typed, so a script (a `.lua` file, or a `lua_filter@…` style
/// entry in a configuration file) must not take effect just because a file landed in the folder:
/// applying waits for a yes to each script that is new or changed since the last one. What a package
/// ships itself is not the user's to confirm: an entry or file identical to the package's own at the
/// same path is left out.
struct UserScripts: Sendable {
    let state: UserConfigState

    /// One script: `id` is what the user sees (a file path, or the file and its entry), `hash` what it was.
    struct Entry: Equatable, Hashable, Sendable {
        let id: String
        let hash: String
        /// Identifies exactly this script, path and content.
        var key: String { id + "@" + hash }
        /// The file the script is in.
        var path: String { id.components(separatedBy: ": ").first ?? id }
    }

    private struct Record: Codable {
        var confirmed: [String] = []
        var riskAccepted = false
    }

    private static let maximumConfirmed = 1000

    /// The scripts of the folder's `files` (relative path to bytes) that differ from the package's own, in path order.
    static func entries(_ files: [String: Data], package: PackageFiles) -> [Entry] {
        var found: [Entry] = []
        for path in files.keys.sorted() {
            guard let data = files[path] else { continue }
            if path.hasSuffix(".lua") {
                if package.read(path) != data { found.append(Entry(id: path, hash: sha256Hex(data))) }
            } else if path.hasSuffix(".yaml") {
                let shipped = Set(package.read(path).map { components(path, $0) } ?? [])
                for component in components(path, data) where !shipped.contains(component) {
                    found.append(Entry(id: "\(path): \(component)", hash: sha256Hex(Data(component.utf8))))
                }
            }
        }
        return found
    }

    /// The scripts among `files` the user has not agreed to yet.
    func unconfirmed(_ files: [String: Data], package: PackageFiles) -> [Entry] {
        let agreed = Set(record().confirmed)
        return Self.entries(files, package: package).filter { !agreed.contains($0.key) }
    }

    /// The Lua component entries the user has agreed to, by their own content: a record is
    /// `<file>: <component>@<hash>` (the component holds an `@` itself), and counts only while the hash
    /// is that of the component.
    func confirmedComponents() -> Set<String> {
        Set(
            record().confirmed.compactMap { key -> String? in
                guard let at = key.lastIndex(of: "@") else { return nil }
                let hash = String(key[key.index(after: at)...])
                let id = String(key[..<at])
                guard let separator = id.range(of: ": ") else { return nil }
                let component = String(id[separator.upperBound...])
                return !component.isEmpty && sha256Hex(Data(component.utf8)) == hash ? component : nil
            })
    }

    /// Whether the user has accepted the risk of running their own scripts (the first time they apply one).
    func riskAccepted() -> Bool { record().riskAccepted }

    /// Records that the user agreed to use `entries`, and that they know what a script can do.
    func accept(_ entries: [Entry]) {
        UserConfigState.lock.lock()
        defer { UserConfigState.lock.unlock() }
        var current = record()
        for entry in entries where !current.confirmed.contains(entry.key) { current.confirmed.append(entry.key) }
        current.confirmed = Array(current.confirmed.suffix(Self.maximumConfirmed))
        current.riskAccepted = true
        try? state.write(current, to: state.scriptsFile)
    }

    private func record() -> Record { state.read(state.scriptsFile, as: Record.self) ?? Record() }

    /// The Lua components a YAML file names, read from decoded scalar values only; none when it is not
    /// readable YAML (applying refuses such a file).
    static func components(_ name: String, _ data: Data) -> [String] {
        guard let text = UserConfigFiles.decode(data) else { return [] }
        let result = UserConfigFiles.read(name, text)
        return result.error == nil ? UserConfigSafety.luaComponents(result.root) : []
    }
}
