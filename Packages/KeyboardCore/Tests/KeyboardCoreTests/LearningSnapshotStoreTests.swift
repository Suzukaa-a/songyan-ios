import XCTest

@testable import KeyboardCore

final class LearningSnapshotStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("learning-snapshots-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func archive(source: String = "scheme:a", revision: String = "revision1") throws -> LearningBackupArchive {
        try LearningBackupArchive(
            sourceID: source, resourceRevision: revision, sourceName: source, engineVersion: "test", createdAt: Date(),
            dictionaries: [.init(name: "words", data: Data("learned".utf8))])
    }
    private var store: LearningSnapshotStore { .init(root: root.appendingPathComponent("snapshots")) }
    private var transfer: LearningTransferStore { .init(directory: root.appendingPathComponent("transfer")) }

    func testExportsRetainMultipleSourcesAndVersions() throws {
        try store.save(archive())
        try store.save(archive(source: "scheme:b"))
        try store.save(archive(revision: "revision2"))
        XCTAssertEqual(try store.snapshots().count, 3)
        XCTAssertEqual(try store.snapshot(sourceID: "scheme:a", revision: "revision1")?.resourceRevision, "revision1")
    }

    func testRestoreWaitsForMatchingSchemeAndSubmitsOnce() throws {
        try store.save(archive())
        try store.prepareRestore()
        XCTAssertFalse(try store.advanceRestore(sourceID: "scheme:b", revision: "revision1", transfer: transfer))
        XCTAssertNil(try transfer.read())
        XCTAssertTrue(try store.advanceRestore(sourceID: "scheme:a", revision: "revision1", transfer: transfer))
        let first = try XCTUnwrap(transfer.read())
        XCTAssertEqual(first.operation, .restore)
        XCTAssertTrue(try store.advanceRestore(sourceID: "scheme:a", revision: "revision1", transfer: transfer))
        XCTAssertEqual(try transfer.read()?.id, first.id)
    }

    func testFreshInstallCanPersistEmptySafetyBeforeRestoring() throws {
        try store.save(archive())
        try store.prepareRestore()
        _ = try store.advanceRestore(sourceID: "scheme:a", revision: "revision1", transfer: transfer)
        let request = try XCTUnwrap(transfer.read())
        let lease = try XCTUnwrap(transfer.acquireWorkerLease())
        defer { lease.release() }
        _ = try transfer.claim(
            requestID: request.id, sourceID: request.sourceID, resourceRevision: request.resourceRevision, lease: lease)
        XCTAssertThrowsError(try transfer.completeRestore(requestID: request.id, lease: lease))
        try transfer.saveEmptySafetyBackup(requestID: request.id, lease: lease)
        XCTAssertEqual(try transfer.completeRestore(requestID: request.id, lease: lease).status, .succeeded)
        XCTAssertFalse(try store.advanceRestore(sourceID: "scheme:a", revision: "revision1", transfer: transfer))
        XCTAssertTrue(try store.pendingRestores().isEmpty)
    }

    func testFailedMergeIsNotAutomaticallyRepeated() throws {
        try store.save(archive())
        try store.prepareRestore()
        _ = try store.advanceRestore(sourceID: "scheme:a", revision: "revision1", transfer: transfer)
        let request = try XCTUnwrap(transfer.read())
        let lease = try XCTUnwrap(transfer.acquireWorkerLease())
        defer { lease.release() }
        _ = try transfer.claim(
            requestID: request.id, sourceID: request.sourceID, resourceRevision: request.resourceRevision, lease: lease)
        _ = try transfer.fail(requestID: request.id, lease: lease, message: "failed")
        XCTAssertTrue(try store.advanceRestore(sourceID: "scheme:a", revision: "revision1", transfer: transfer))
        XCTAssertEqual(try transfer.read()?.status, .failed)
        XCTAssertEqual(try transfer.read()?.id, request.id)
    }

    func testAutomaticExportIsThrottledEvenWhenNoLearningExists() throws {
        let now = Date()
        XCTAssertTrue(try store.shouldAutomaticallyExport(sourceID: "scheme:a", revision: "r", now: now))
        try store.markAutomaticAttempt(sourceID: "scheme:a", revision: "r", date: now)
        XCTAssertFalse(
            try store.shouldAutomaticallyExport(sourceID: "scheme:a", revision: "r", now: now.addingTimeInterval(2)))
        XCTAssertTrue(
            try store.shouldAutomaticallyExport(sourceID: "scheme:a", revision: "r", now: now.addingTimeInterval(901)))
    }

    func testUnchangedLearningDoesNotCreateRepeatedFullBackups() throws {
        let first = try archive()
        try store.save(first)
        let later = try LearningBackupArchive(
            sourceID: first.sourceID, resourceRevision: first.resourceRevision, sourceName: first.sourceName,
            engineVersion: first.engineVersion, createdAt: first.createdAt.addingTimeInterval(900),
            dictionaries: first.dictionaries)
        try store.save(later)
        XCTAssertEqual(try store.snapshot(sourceID: first.sourceID, revision: first.resourceRevision), first)
    }

    func testRebuiltDependencyRetargetsOnlyItsUnsubmittedLearning() throws {
        try store.save(archive())
        try store.save(archive(source: "scheme:b"))
        try store.prepareRestore()
        try store.retargetPendingRestore(sourceID: "scheme:a", revision: "rebuilt")
        XCTAssertEqual(try store.pendingRestores().count, 2)
        XCTAssertFalse(try store.advanceRestore(sourceID: "scheme:a", revision: "revision1", transfer: transfer))
        XCTAssertTrue(try store.advanceRestore(sourceID: "scheme:a", revision: "rebuilt", transfer: transfer))
        XCTAssertEqual(try transfer.read()?.resourceRevision, "rebuilt")
        XCTAssertNotNil(try store.snapshot(sourceID: "scheme:a", revision: "revision1"))
        // Retrying dependency installation must not submit a second merge.
        try store.retargetPendingRestore(sourceID: "scheme:a", revision: "rebuilt-again")
        XCTAssertNil(try store.snapshot(sourceID: "scheme:a", revision: "rebuilt-again"))
    }

    func testDependencyRestoreWaitsAndKeepsOriginalLearningWhenNewRevisionExports() throws {
        let original = try archive()
        try store.save(original)
        try store.prepareRestore(waitingForDependencies: true)
        XCTAssertTrue(try store.advanceRestore(sourceID: "scheme:a", revision: "revision1", transfer: transfer))
        XCTAssertNil(try transfer.read())
        let fresh = try LearningBackupArchive(
            sourceID: "scheme:a", resourceRevision: "rebuilt", sourceName: "scheme:a",
            engineVersion: "test", createdAt: Date().addingTimeInterval(60),
            dictionaries: [.init(name: "words", data: Data("new installation".utf8))])
        try store.save(fresh)
        try store.retargetPendingRestore(sourceID: "scheme:a", revision: "rebuilt")
        XCTAssertTrue(try store.advanceRestore(sourceID: "scheme:a", revision: "rebuilt", transfer: transfer))
        let request = try XCTUnwrap(transfer.read())
        let lease = try XCTUnwrap(transfer.acquireWorkerLease())
        defer { lease.release() }
        _ = try transfer.claim(
            requestID: request.id, sourceID: request.sourceID,
            resourceRevision: request.resourceRevision, lease: lease)
        let restored = try transfer.readRestoreInput(requestID: request.id, lease: lease)
        XCTAssertEqual(restored.resourceRevision, "rebuilt")
        XCTAssertEqual(restored.dictionaries, original.dictionaries)
        XCTAssertEqual(try store.snapshot(sourceID: "scheme:a", revision: "rebuilt"), fresh)
    }
}
