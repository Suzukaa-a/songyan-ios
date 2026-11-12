import Foundation

/// The local state of one script addon. The script's bytes live in script.js next to
/// this file; this JSON carries only what the host tracks. Secret values never live
/// here: only their keys, so the host knows which fields to ask for.
public struct ScriptAddonState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var enabled: Bool
    public var order: Int
    /// Where a downloaded addition came from, when it came from a link.
    public var sourceURL: String?
    /// Digest of the declarations the user confirmed; nil until confirmed once.
    public var confirmedDigest: String?
    /// Filled settings, by the keys the declarations name.
    public var settings: [String: String]
    /// Keys whose values live in the Keychain, never in this file.
    public var secretKeys: [String]
    /// SHA-256 of script.js, so a changed file is visible without reading it.
    public var scriptDigest: String
    public var scriptByteCount: Int
    public var addedAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = ScriptAddonState.currentSchemaVersion, id: String,
        enabled: Bool = true, order: Int, sourceURL: String? = nil,
        confirmedDigest: String? = nil, settings: [String: String] = [:],
        secretKeys: [String] = [], scriptDigest: String, scriptByteCount: Int,
        addedAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.enabled = enabled
        self.order = order
        self.sourceURL = sourceURL
        self.confirmedDigest = confirmedDigest
        self.settings = settings
        self.secretKeys = secretKeys
        self.scriptDigest = scriptDigest
        self.scriptByteCount = scriptByteCount
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    public func decoded() throws -> ScriptAddonState {
        guard schemaVersion <= ScriptAddonState.currentSchemaVersion else {
            throw ScriptAddonStore.StoreError.unsupportedStateVersion(schemaVersion)
        }
        return self
    }
}
