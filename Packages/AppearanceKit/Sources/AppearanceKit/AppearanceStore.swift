import CandidateKit
import Foundation
import SkinKit

/// Unified appearance snapshot: selection + content commit atomically.
/// `selectedID == document.id` and the document's internal identities agree
/// (`document.identityIsConsistent`), so skin and candidate bar always come from the same commit.
public struct AppearanceSnapshot: Codable, Equatable, Sendable {
    public var selectedID: String
    public var document: AppearanceDocument

    public init(document: AppearanceDocument = .systemDefault) {
        self.document = document
        self.selectedID = document.id
    }

    /// Runtime consistency check (shared by the read path and tests).
    public var identityIsConsistent: Bool {
        selectedID == document.id && document.identityIsConsistent
    }

    public var identityDescription: String {
        "\(selectedID)|\(document.identityDescription)"
    }
}

/// Where a read result came from.
public enum AppearanceSnapshotSource: String, Equatable, Sendable {
    /// `active.json` was read successfully.
    case applied
    /// Nothing usable (missing or unreadable): built-in system default.
    case systemDefault
}

/// Runtime read result: never throws; an unreadable snapshot yields the built-in default plus a clear error.
public struct AppearanceReadResult: Equatable, Sendable {
    public var snapshot: AppearanceSnapshot
    public var source: AppearanceSnapshotSource
    /// A clear error (non-nil when the snapshot exists but cannot be read).
    public var error: String?

    public init(snapshot: AppearanceSnapshot, source: AppearanceSnapshotSource, error: String? = nil) {
        self.snapshot = snapshot
        self.source = source
        self.error = error
    }

    public var identityIsConsistent: Bool { snapshot.identityIsConsistent }
}

public struct AppearanceCatalog: Sendable {
    public let documents: [AppearanceDocument]
    public let unreadable: [UnreadableAppearance]

    public init(documents: [AppearanceDocument], unreadable: [UnreadableAppearance]) {
        self.documents = documents
        self.unreadable = unreadable
    }
}

public struct UnreadableAppearance: Identifiable, Equatable, Sendable {
    public let fileName: String
    public let reason: String
    public var id: String { fileName }

    public init(fileName: String, reason: String) {
        self.fileName = fileName
        self.reason = reason
    }
}

/// The host writes; the extension only reads. Selection and content commit atomically in one file, so
/// one snapshot read yields a consistent skin + candidate layout.
public struct AppearanceStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var active: URL { directory.appendingPathComponent("active.json") }

    // MARK: - List / save / delete

    public func list() throws -> [AppearanceDocument] {
        try catalog().documents
    }

    public func catalog() throws -> AppearanceCatalog {
        let builtins = [AppearanceDocument.systemDefault] + AppearanceDocument.builtinPresets
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return AppearanceCatalog(documents: builtins, unreadable: [])
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(AppearanceDocument.fileExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var documents: [AppearanceDocument] = []
        var unreadable: [UnreadableAppearance] = []
        for file in files {
            do {
                let file = try libraryFile(named: file.lastPathComponent)
                let document = try AppearanceDocument.decode(try Data(contentsOf: file))
                let stem = String(file.lastPathComponent.dropLast(AppearanceDocument.fileExtension.count))
                guard stem == document.id else {
                    throw AppearanceError(
                        String(
                            format: String(localized: "appearance.error.fileNameMismatch", bundle: .module),
                            file.lastPathComponent))
                }
                documents.append(document)
            } catch {
                unreadable.append(
                    UnreadableAppearance(fileName: file.lastPathComponent, reason: error.localizedDescription))
            }
        }
        // Built-in preset copies saved in the shared library for application are not listed twice.
        return AppearanceCatalog(
            documents: builtins + documents.filter { !$0.isBuiltin }.sorted { $0.name < $1.name },
            unreadable: unreadable)
    }

    public func readUnreadable(_ item: UnreadableAppearance) throws -> Data {
        try Data(contentsOf: libraryFile(named: item.fileName))
    }

    public func removeUnreadable(_ item: UnreadableAppearance) throws {
        try FileManager.default.removeItem(at: libraryFile(named: item.fileName))
    }

    private func libraryFile(named fileName: String) throws -> URL {
        guard fileName.hasSuffix(AppearanceDocument.fileExtension),
            fileName.count > AppearanceDocument.fileExtension.count,
            !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains("\0")
        else { throw AppearanceError(String(localized: "appearance.error.invalidFileName", bundle: .module)) }
        let file = directory.appendingPathComponent(fileName)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AppearanceError(String(localized: "appearance.error.unreadableFile", bundle: .module))
        }
        return file
    }

    public func save(_ document: AppearanceDocument, replacing: Bool = false) throws {
        guard !document.isSystemDefault else {
            throw AppearanceError(
                String(localized: "appearance.error.systemDefaultReadOnly", bundle: .module))
        }
        let data = try document.encoded()
        let file = directory.appendingPathComponent(document.id + AppearanceDocument.fileExtension)
        if !replacing && FileManager.default.fileExists(atPath: file.path) {
            throw AppearanceError(String(localized: "appearance.error.duplicateID", bundle: .module))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    public func remove(_ id: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AppearanceError(String(localized: "appearance.error.invalidID", bundle: .module))
        }
        guard id != AppearanceDocument.systemDefaultID else {
            throw AppearanceError(
                String(localized: "appearance.error.cannotDeleteSystemDefault", bundle: .module))
        }
        let file = directory.appendingPathComponent(id + AppearanceDocument.fileExtension)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw AppearanceError(
                String(
                    format: String(localized: "appearance.error.notFound", bundle: .module), id))
        }
        // Only the project file is deleted; the applied snapshot keeps its content until the next apply.
        try FileManager.default.removeItem(at: file)
    }

    // MARK: - Apply (atomic)

    /// Validate, then write one snapshot atomically: skin, candidate area and display mode commit together.
    public func apply(_ document: AppearanceDocument) throws {
        let validated = try AppearanceDocument.decode(document.encoded())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(AppearanceSnapshot(document: validated)).write(to: active, options: .atomic)
    }

    // MARK: - Read

    /// Strict read: a missing snapshot is the built-in default; a corrupt one throws.
    public func readSnapshot() throws -> AppearanceSnapshot {
        guard FileManager.default.fileExists(atPath: active.path) else { return .init() }
        return try decodeSnapshot(active)
    }

    /// Runtime read entry: never throws; an unreadable snapshot yields the built-in default plus an error.
    public func read() -> AppearanceReadResult {
        guard FileManager.default.fileExists(atPath: active.path) else {
            return AppearanceReadResult(snapshot: .init(), source: .systemDefault)
        }
        do {
            return AppearanceReadResult(snapshot: try decodeSnapshot(active), source: .applied)
        } catch {
            return AppearanceReadResult(snapshot: .init(), source: .systemDefault, error: error.localizedDescription)
        }
    }

    private func decodeSnapshot(_ file: URL) throws -> AppearanceSnapshot {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 512 * 1024 else {
            throw AppearanceError(String(localized: "appearance.error.snapshotTooLarge", bundle: .module))
        }
        return try decodeSnapshot(data: Data(contentsOf: file))
    }

    private func decodeSnapshot(data: Data) throws -> AppearanceSnapshot {
        let value = try JSONDecoder().decode(AppearanceSnapshot.self, from: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let document = object["document"]
        else { throw AppearanceError(String(localized: "appearance.error.snapshotMalformed", bundle: .module)) }
        // Strict decoding (unknown fields, wrong versions, invalid values, mixed identities are rejected) before any use.
        let decoded = try AppearanceDocument.decode(JSONSerialization.data(withJSONObject: document))
        guard decoded == value.document.normalized() else {
            throw AppearanceError(
                String(localized: "appearance.error.snapshotContentMismatch", bundle: .module))
        }
        guard value.selectedID == value.document.id else {
            throw AppearanceError(
                String(localized: "appearance.error.snapshotSelectionMismatch", bundle: .module))
        }
        guard value.document.identityIsConsistent else {
            throw AppearanceError(
                String(
                    format: String(localized: "appearance.error.snapshotIdentityMismatch", bundle: .module),
                    value.document.identityDescription))
        }
        return value
    }
}
