import Foundation
import KeyboardCore

/// The scheme in use, as the learning transfer sees it.
public struct PackageLearningSource: Equatable, Sendable {
    public let sourceID: String
    public let resourceRevision: String
    public let sourceName: String

    public init(sourceID: String, resourceRevision: String, sourceName: String) {
        self.sourceID = sourceID
        self.resourceRevision = resourceRevision
        self.sourceName = sourceName
    }
}

public enum PackageLearningError: Error, Equatable {
    /// The package is not the scheme in use at its installed version, even after using it.
    case notInUse
    /// There is nothing to merge.
    case nothingToMerge
}

/// Merging the learned words a scheme package shipped, once the user agreed. Only the scheme in use
/// has learning data to merge into, so a package that is not in use is used first. The words go out
/// as the same learning transfer request every other import uses, which the keyboard checks against
/// its own publication again; this only refuses early and never touches the installed package.
public struct PackageLearningMerge: Sendable {
    public let snapshots: CollectedSnapshots
    /// The learning identity of the package: its source key and the revision installed now.
    public let packageSourceID: String
    public let installedRevision: @Sendable () async throws -> String
    public let isInUse: @Sendable () async -> Bool
    public let putInUse: @Sendable () async throws -> Void
    public let currentSource: @Sendable () async throws -> PackageLearningSource?
    public let submit: @Sendable (LearningBackupArchive) async throws -> Void

    public init(
        snapshots: CollectedSnapshots, packageSourceID: String,
        installedRevision: @escaping @Sendable () async throws -> String,
        isInUse: @escaping @Sendable () async -> Bool,
        putInUse: @escaping @Sendable () async throws -> Void,
        currentSource: @escaping @Sendable () async throws -> PackageLearningSource?,
        submit: @escaping @Sendable (LearningBackupArchive) async throws -> Void
    ) {
        self.snapshots = snapshots
        self.packageSourceID = packageSourceID
        self.installedRevision = installedRevision
        self.isInUse = isInUse
        self.putInUse = putInUse
        self.currentSource = currentSource
        self.submit = submit
    }

    public func accept(now: Date = Date()) async throws {
        guard !snapshots.snapshots.isEmpty else { throw PackageLearningError.nothingToMerge }
        if !(await isInUse()) { try await putInUse() }
        let revision = try await installedRevision()
        guard let source = try await currentSource(), source.sourceID == packageSourceID,
            source.resourceRevision == revision
        else { throw PackageLearningError.notInUse }
        let archive = try RimeSnapshotImportSummary.archive(
            from: snapshots, sourceID: source.sourceID, resourceRevision: source.resourceRevision,
            sourceName: source.sourceName, now: now)
        try await submit(archive)
    }
}
