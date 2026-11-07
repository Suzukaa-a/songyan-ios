import Foundation

/// Immutable file list for a reviewed upstream recipe or a checked user dictionary import.
public struct RecipeManifest: Codable, Sendable {
    public enum Origin: String, Codable, Sendable { case userDictionary, userScheme, userRecipe }
    public struct File: Codable, Sendable {
        public let path: String
        public let sha256: String
        public let size: Int
    }
    public let id: String
    public let repository: String
    public let revision: String
    public let recipePath: String
    public let license: String
    public let schemaID: String
    public let requiredComponents: [String]
    public let files: [File]
    /// Absent for legacy reviewed GitHub manifests. User imports record actual URLs in import.json.
    public let origin: Origin?

    public init(
        id: String, repository: String, revision: String, recipePath: String,
        license: String, schemaID: String, requiredComponents: [String], files: [File],
        origin: Origin? = nil
    ) {
        self.id = id
        self.repository = repository
        self.revision = revision
        self.recipePath = recipePath
        self.license = license
        self.schemaID = schemaID
        self.requiredComponents = requiredComponents
        self.files = files
        self.origin = origin
    }
}

public enum RecipeInstallError: Error, LocalizedError {
    case invalidManifest(String)
    case invalidResource(String)
    case missingSchemaFiles([String])
    case http(Int)
    case busy
    case missingComponents([String])
    /// The scheme needs grammar models that were not supplied with it; the paths are the files to add.
    case missingGrammarModels([String])
    case deployment(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let value): return PackageText.format("recipe.error.information", value)
        case .invalidResource(let value): return PackageText.format("recipe.error.fileCheck", value)
        case .missingSchemaFiles(let values):
            return PackageText.format("recipe.error.schemaFilesMissed", values.joined(separator: "、"))
        case .http(let code): return PackageText.format("recipe.error.httpFailure", code)
        case .busy: return PackageText.string("recipe.error.busy")
        case .missingComponents(let values):
            return PackageText.format("recipe.error.componentsMissed", values.joined(separator: "、"))
        case .missingGrammarModels(let values):
            return PackageText.format("recipe.error.grammarModelsMissed", values.joined(separator: "、"))
        case .deployment(let value): return PackageText.format("recipe.error.installFailed", value)
        }
    }

    /// Short description for ordinary UI (no paths, IDs or engine details); technical detail
    /// lives in `errorDescription`, for diagnostic logs or developer options only.
    public var userFacingDescription: String {
        switch self {
        case .invalidManifest, .invalidResource, .missingSchemaFiles:
            return PackageText.string("recipe.error.filesIncomplete")
        case .http: return PackageText.string("recipe.error.downloadFailed")
        case .busy: return PackageText.string("recipe.error.busy")
        case .missingComponents: return PackageText.string("recipe.error.missingComponents")
        case .missingGrammarModels: return PackageText.string("recipe.error.missingGrammarModels")
        case .deployment: return PackageText.string("recipe.error.deploymentFailed")
        }
    }
}

public struct InstalledRecipe: Codable, Sendable {
    public let id: String
    public let revision: String
    public let generation: String
    public let schemaID: String
    public let activatedAt: Date
}

public struct RecipeStatus: Sendable {
    public let active: InstalledRecipe?
}

/// Both paths from one atomic marker read, so readers never mix generations during an update.
public struct ActiveRecipe: Sendable {
    public let installation: InstalledRecipe
    public let resourceURL: URL
    public let userDataURL: URL
}

public struct RecipeDeployment: Sendable {
    public let manifest: RecipeManifest
    public let resourceURL: URL
    /// Private snapshot, including user dictionaries/customizations, excluding stale build output.
    /// This becomes the live user directory after activation. Do not keep using the old directory.
    public let userDataURL: URL

    public func declaredEntry(in enabledSchemaIDs: [String]) throws -> String {
        if enabledSchemaIDs.contains(manifest.schemaID) { return manifest.schemaID }
        if (manifest.origin == .userRecipe || manifest.origin == .userScheme),
            let surviving = enabledSchemaIDs.first
        {
            return surviving
        }
        throw RecipeInstallError.deployment(
            PackageText.format("recipe.error.declaredSchemaNotEnabled", manifest.schemaID))
    }
}

/// The bridge must report registered components and perform real deploy + schema/input validation.
public struct RecipeDeploymentReceipt: Sendable {
    public let availableComponents: Set<String>
    public let validatedSchemaID: String
    /// Every enabled schema, after dependency/component/select/grammar validation.
    /// Core checks this set against the deployed build/default.yaml before committing.
    public let validatedEnabledSchemaIDs: [String]?
    /// Companions generated by the deploy callback, keyed by generated schema ID with their source schema ID.
    public let generatedSchemaSources: [String: String]
    public init(
        availableComponents: Set<String>, validatedSchemaID: String, validatedEnabledSchemaIDs: [String]? = nil,
        generatedSchemaSources: [String: String] = [:]
    ) {
        self.availableComponents = availableComponents
        self.validatedSchemaID = validatedSchemaID
        self.validatedEnabledSchemaIDs = validatedEnabledSchemaIDs
        self.generatedSchemaSources = generatedSchemaSources
    }
}
