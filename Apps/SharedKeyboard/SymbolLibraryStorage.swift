import Foundation
import KeyboardCore
import QuickContentKit
import os

// MARK: - Storage directory resolution (same discipline as the layout/skin directories: shared container first, local fallback)

/// Symbol library directory resolution. Prefers the App Group shared container `KeyboardSymbols/`
/// (host writes, extension reads; same probe discipline as `RimePaths.layoutStoreDirectory`); if the
/// container is not writable, falls back to the process-local Application Support (the extension's own
/// container, which still persists recents). A keyboard without Full Access reads the shared
/// directory as is and never writes it.
public enum SymbolLibraryStorage {
    /// Caches the resolved result in-process: the probe (create directory + write/read/delete) runs once per process, not on every panel open.
    private static let cachedDirectory = OSAllocatedUnfairLock<URL?>(initialState: nil)

    public static func defaultStoreDirectory() -> URL {
        // Read-only, the host's library is read where it is, unprobed and uncached, so a
        // later writable process still probes it.
        if !KeyboardRecipeStore.canWriteSharedContainer, let shared = sharedDirectory() { return shared }
        return cachedDirectory.withLock { cached in
            if let cached { return cached }
            let resolved = resolveStoreDirectory()
            cached = resolved
            return resolved
        }
    }

    /// Whether this process may write `directory`: the shared one only with Full Access.
    static func allowsWrites(to directory: URL) -> Bool {
        KeyboardRecipeStore.canWriteSharedContainer || directory != sharedDirectory()
    }

    private static func sharedDirectory() -> URL? {
        KeyboardRecipeStore.sharedContainerURL()?
            .appendingPathComponent(SymbolCatalogStore.sharedDirectoryName, isDirectory: true)
    }

    private static func resolveStoreDirectory() -> URL {
        RimePaths.probedStoreDirectory(
            sharedName: SymbolCatalogStore.sharedDirectoryName,
            localName: SymbolCatalogStore.sharedDirectoryName, label: "symbol"
        ).url
    }
}

// MARK: - Serial symbol store (the main thread only publishes results)

/// Directory probes create files and recent mutations perform read-modify-write;
/// keep them off the read-only resource queue and serialize across panel models.
enum SymbolLibraryWriteQueue {
    private static let queue = SerialIOQueue(label: "app.songyan.symbolLibrary.write", qos: .utility)

    static func async<T>(_ body: @escaping @Sendable () -> T) async -> sending T {
        await queue.async(body)
    }
}

// `directory` is confined to SymbolLibraryWriteQueue.
final class SymbolLibraryIOWorker: @unchecked Sendable {
    struct Outcome: Sendable {
        var directory: URL
        var catalog: SymbolCatalog?
        var catalogReadError: String?
        var texts: [String]?
        var persistenceNote: String?
        var updatesPersistenceNote = false
        var isRead = false
        /// Uses retained in this session because the directory is read-only.
        var unstoredUses: [String] = []
    }

    /// Confined to SymbolLibraryWriteQueue, including first-use resolution.
    private var directory: URL?
    init(directory: URL?) { self.directory = directory }

    private func resolveDirectory() -> URL {
        if let directory { return directory }
        let resolved = SymbolLibraryStorage.defaultStoreDirectory()
        directory = resolved
        return resolved
    }

    func load() async -> Outcome {
        let directory = await SymbolLibraryWriteQueue.async { self.resolveDirectory() }
        do {
            return try await KeyboardResourceReadQueue.async {
                var catalogError: String?
                let catalog = SymbolCatalogStore(directory: directory).loadActive {
                    catalogError = $0.localizedDescription
                }
                var recentError: String?
                let texts = RecentSymbolStore(directory: directory).read {
                    recentError = "无法读取最近使用记录：\($0.localizedDescription)"
                }
                return Outcome(
                    directory: directory, catalog: catalog,
                    catalogReadError: catalogError, texts: texts,
                    persistenceNote: recentError, updatesPersistenceNote: recentError != nil, isRead: true)
            }
        } catch {
            return Outcome(
                directory: directory, catalogReadError: error.localizedDescription,
                persistenceNote: "无法读取符号库：\(error.localizedDescription)",
                updatesPersistenceNote: true, isRead: true)
        }
    }

    func record(_ texts: [String]) async -> Outcome {
        await SymbolLibraryWriteQueue.async {
            let directory = self.resolveDirectory()
            // Read-only: the insert stands, the stored recents stay untouched and the
            // use is kept for this keyboard session only.
            let store = RecentSymbolStore(directory: directory)
            guard SymbolLibraryStorage.allowsWrites(to: directory) else {
                // Only the latest distinct uses can affect MRU; coalesce before publishing on main.
                var seen = Set<String>()
                var newest: [String] = []
                for text in texts.reversed() where seen.insert(text).inserted {
                    newest.append(text)
                    if newest.count == store.limit { break }
                }
                return Outcome(directory: directory, unstoredUses: Array(newest.reversed()))
            }
            let result = store.record(texts)
            return Outcome(
                directory: directory, texts: result.saveError == nil ? result.texts : nil,
                persistenceNote: result.saveError.map { "未能保存最近使用记录，已保留原有记录：\($0.localizedDescription)" },
                updatesPersistenceNote: true)
        }
    }

    func clear() async -> Outcome {
        await SymbolLibraryWriteQueue.async {
            let directory = self.resolveDirectory()
            guard SymbolLibraryStorage.allowsWrites(to: directory) else {
                return Outcome(
                    directory: directory,
                    persistenceNote: "未能清空最近使用记录，请在系统设置中打开「允许完全访问」后重试",
                    updatesPersistenceNote: true)
            }
            do {
                try RecentSymbolStore(directory: directory).clear()
                return Outcome(directory: directory, texts: [], updatesPersistenceNote: true)
            } catch {
                return Outcome(
                    directory: directory,
                    persistenceNote: "未能清空最近使用记录：\(error.localizedDescription)",
                    updatesPersistenceNote: true)
            }
        }
    }
}
