import Foundation

/// One user-facing result combines publication identity with a validated runtime receipt.
public enum GrammarModelStatus: Equatable, Sendable {
    case inactive, olderVersion, unverifiedVersion, noInputMethod, disabled
    case awaitingLoad(model: String), loaded(model: String)

    /// The caller must validate a receipt against the current source, runtime schema and model path.
    public static func resolve(
        publication: ModelPublicationState, enabled: Bool,
        hasSelection: Bool, modelName: String?, loadConfirmed: Bool
    ) -> Self {
        guard enabled else { return .inactive }
        switch publication {
        case .notPublished, .otherSource: return .inactive
        case .olderInstallation: return .olderVersion
        case .revisionOnly: return .unverifiedVersion
        case .currentInstallation: break
        }
        guard hasSelection else { return .noInputMethod }
        guard let modelName else { return .disabled }
        return loadConfirmed ? .loaded(model: modelName) : .awaitingLoad(model: modelName)
    }

    public var message: String {
        switch self {
        case .inactive: return PackageText.string("grammarState.inactive")
        case .olderVersion: return PackageText.string("grammarState.olderVersion")
        case .unverifiedVersion: return PackageText.string("grammarState.unverifiedVersion")
        case .noInputMethod: return PackageText.string("grammarState.noInputMethod")
        case .disabled: return PackageText.string("grammarState.disabled")
        case .awaitingLoad(let model): return PackageText.format("grammarState.awaitingLoad", model)
        case .loaded(let model): return PackageText.format("grammarState.loaded", model)
        }
    }
}

/// Publication identity is independent of installation and of runtime model loading.
public enum ModelPublicationState: Equatable, Sendable {
    case notPublished, otherSource, olderInstallation, revisionOnly, currentInstallation

    public static func resolve(
        sourceMatches: Bool, installedRevision: String,
        installedGeneration: String, publishedRevision: String?,
        publishedGeneration: String?, hostGeneration: String?
    ) -> Self {
        guard let publishedRevision, let publishedGeneration, !publishedGeneration.isEmpty else { return .notPublished }
        guard sourceMatches else { return .otherSource }
        guard installedRevision == publishedRevision else { return .olderInstallation }
        guard let hostGeneration else { return .revisionOnly }
        return hostGeneration == installedGeneration ? .currentInstallation : .olderInstallation
    }

    public var message: String {
        switch self {
        case .notPublished: return PackageText.string("modelState.notPublished")
        case .otherSource: return PackageText.string("modelState.otherSource")
        case .olderInstallation: return PackageText.string("modelState.olderInstallation")
        case .revisionOnly: return PackageText.string("modelState.revisionOnly")
        case .currentInstallation: return PackageText.string("modelState.currentInstallation")
        }
    }
}
