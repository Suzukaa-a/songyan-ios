import Foundation
import KeyboardCore
import PackageManager

/// Roots of the host app's private stores (never shared with the keyboard through the App Group).
enum HostStorePaths {
    /// Falls back to Library, never Documents: Documents is listed in the Files app.
    static var applicationSupport: URL {
        let fm = FileManager.default
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
    }
    /// The user's Rime files; Documents is shown in the Files app under the app's name.
    static var rimeConfig: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(RimeConfigFolder.name, isDirectory: true)
    }
    /// What the app knows about those files (which replace a package file, which scripts the user agreed to);
    /// private, because any app the user lets into the folder can write the files themselves.
    static var rimeConfigState: URL {
        applicationSupport.appendingPathComponent("RimeConfigState", isDirectory: true)
    }
    nonisolated static var rimeConfigScopes: RimeConfigScopes {
        RimeConfigScopes(root: rimeConfig, state: rimeConfigState)
    }
    /// Whose folder holds the user's Rime files for the imported dictionary's input methods.
    nonisolated static let dictionaryRimeConfigID = "user-pinyin"

    /// The folder of the user's Rime files for the package `id` installed in `store`, and its private
    /// state. A package that is not installed and never had a folder gets none.
    nonisolated static func rimeConfig(id: String, store: URL) -> (folder: URL?, state: URL) {
        let scopes = rimeConfigScopes
        let folder = try? scopes.folder(id) { rimeConfigName(id: id, store: store) }
        return (folder ?? nil, scopes.stateDirectory(id))
    }

    /// The name of the package installed in `store`, for its folder; nil when nothing is installed there.
    nonisolated private static func rimeConfigName(id: String, store: URL) -> String? {
        guard let installed = RimeConfigScopes.installedRecipient(store: store) else { return nil }
        if let name = installed.declaredName { return name }
        struct Summary: Decodable { let name: String }
        if let generation = installed.generation,
            let data = try? Data(
                contentsOf: store.appendingPathComponent("versions/\(generation)/resources/host-import-summary.json")),
            let summary = try? JSONDecoder().decode(Summary.self, from: data), !summary.name.isEmpty
        {
            return summary.name
        }
        return id
    }

    /// Earlier versions kept one folder every package read; each installed package gets its own copy of it.
    /// Runs before any package manager reads a folder: at launch and after a backup is restored.
    nonisolated static func migrateRimeConfig() {
        let scopes = rimeConfigScopes
        guard scopes.needsMigration() else { return }
        let schemes = applicationSupport.appendingPathComponent("SchemePackages", isDirectory: true)
        let dictionary = applicationSupport.appendingPathComponent("DictionaryImportStore", isDirectory: true)
        var recipients: [RimeConfigScopes.Recipient] = []
        for slot in (try? FileManager.default.contentsOfDirectory(atPath: schemes.path)) ?? []
        where PublishedKeyboardSourceKey.validPackageID(slot) && !slot.hasPrefix(".") {
            let store = schemes.appendingPathComponent(slot, isDirectory: true)
            if let name = rimeConfigName(id: slot, store: store) { recipients.append(.init(id: slot, name: name)) }
        }
        if let name = rimeConfigName(id: dictionaryRimeConfigID, store: dictionary) {
            recipients.append(.init(id: dictionaryRimeConfigID, name: name))
        }
        do {
            try scopes.migrate(recipients: recipients)
        } catch {
            HostLog.append("rime config migration failed: \(error.localizedDescription)")
        }
    }
}

extension HostStorePaths {
    /// File-size text for UI ("1.2 MB").
    static func fileSizeText(_ bytes: some BinaryInteger) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// On-disk diagnostic log of the host app (Application Support/host.log), shown under Settings > Advanced.
///
/// Callers only enqueue; `DiskLogWriter` writes on its own serial queue, so logging from the
/// main actor never blocks on file I/O.
enum HostLog {
    nonisolated static func append(_ line: String) {
        writer.append(line, to: url)
    }

    static func recent() async -> String? {
        await writer.tail(url)
    }

    static func clear() async -> Bool {
        await writer.clear(url)
    }

    private nonisolated static let writer = DiskLogWriter()
    private nonisolated static let url: URL? = {
        // Earlier builds logged into Documents, which the Files app now lists; drop that copy once.
        if let old = DiskLogWriter.documentsLogURL(named: "host.log") {
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.removeItem(at: old.appendingPathExtension("previous"))
            }
        }
        return HostStorePaths.applicationSupport.appendingPathComponent("host.log")
    }()
}
