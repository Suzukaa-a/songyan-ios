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

    /// Each snapshot sets the keyboard's engine aside, so it is taken at most once a day and only after
    /// the learning data changed; with no learning data there is nothing to take.
    func testAutomaticSnapshotsAreDailyAndOnlyAfterLearningChanged() throws {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        func due(_ at: Date, modified: Date?) throws -> Bool {
            try store.shouldAutomaticallyExport(
                sourceID: "scheme:a", revision: "r", now: at, learningModifiedAt: modified)
        }
        XCTAssertFalse(try due(now, modified: nil))
        XCTAssertTrue(try due(now, modified: now.addingTimeInterval(-60)))
        try store.markAutomaticAttempt(sourceID: "scheme:a", revision: "r", date: now)
        XCTAssertFalse(try due(now.addingTimeInterval(15 * 60), modified: now.addingTimeInterval(60)))
        XCTAssertFalse(try due(now.addingTimeInterval(day), modified: now.addingTimeInterval(-60)))
        XCTAssertTrue(try due(now.addingTimeInterval(day), modified: now.addingTimeInterval(60)))
    }

    func testLearningModifiedAtReadsOnlyTheLearningDatabases() throws {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: user) }
        XCTAssertNil(LearningSnapshotStore.learningModifiedAt(userDirectory: user))
        let database = user.appendingPathComponent("luna_pinyin.userdb")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        let log = database.appendingPathComponent("000003.log")
        try Data("x".utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: log.path)
        try Data("y".utf8).write(to: user.appendingPathComponent("installation.yaml"))
        XCTAssertEqual(LearningSnapshotStore.learningModifiedAt(userDirectory: user), written)
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

    func testAutomaticICloudBackupIsOffUntilTheUserTurnsItOn() throws {
        let suite = "LearningSnapshotStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(LearningSnapshotStore.automaticICloudBackupEnabled(nil))
        XCTAssertFalse(LearningSnapshotStore.automaticICloudBackupEnabled(defaults))
        defaults.set(true, forKey: LearningSnapshotStore.automaticICloudBackupKey)
        XCTAssertTrue(LearningSnapshotStore.automaticICloudBackupEnabled(defaults))
        defaults.set(false, forKey: LearningSnapshotStore.automaticICloudBackupKey)
        XCTAssertFalse(LearningSnapshotStore.automaticICloudBackupEnabled(defaults))
    }

    /// The user's interval: a week waits seven days, off never snapshots, an unknown value is daily.
    func testTheUserPicksTheSnapshotInterval() throws {
        let now = Date()
        let changed = now.addingTimeInterval(60)
        try store.markAutomaticAttempt(sourceID: "scheme:a", revision: "r", date: now)
        func due(after days: Double, every interval: Int) throws -> Bool {
            try store.shouldAutomaticallyExport(
                sourceID: "scheme:a", revision: "r", now: now.addingTimeInterval(days * 86_400),
                learningModifiedAt: changed, days: interval)
        }
        XCTAssertTrue(try due(after: 1, every: 1))
        XCTAssertFalse(try due(after: 6, every: 7))
        XCTAssertTrue(try due(after: 7, every: 7))
        XCTAssertFalse(try due(after: 30, every: 0))

        let suite = "LearningSnapshotStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LearningSnapshotStore.automaticDays(defaults), 1)
        defaults.set(7, forKey: LearningSnapshotStore.automaticIntervalKey)
        XCTAssertEqual(LearningSnapshotStore.automaticDays(defaults), 7)
        defaults.set(5, forKey: LearningSnapshotStore.automaticIntervalKey)
        XCTAssertEqual(LearningSnapshotStore.automaticDays(defaults), 1)
    }

    /// The keyboard copies its learning databases instead of setting its engine aside; the copy
    /// lands whole (or not at all) and a newer copy replaces the older one.
    func testRawCopiesHoldTheDatabasesAndReplaceEachOther() throws {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: user) }
        let database = user.appendingPathComponent("luna_pinyin.userdb")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: database.appendingPathComponent("000003.log"))
        try Data("x".utf8).write(to: user.appendingPathComponent("installation.yaml"))

        try store.saveRawCopy(
            sourceID: "scheme:a", revision: "r", sourceName: "A", userDirectory: user,
            now: Date(timeIntervalSince1970: 1))
        try Data("second".utf8).write(to: database.appendingPathComponent("000003.log"))
        try store.saveRawCopy(
            sourceID: "scheme:a", revision: "r", sourceName: "A", userDirectory: user,
            now: Date(timeIntervalSince1970: 2))

        let copies = try store.rawCopies()
        XCTAssertEqual(copies.count, 1)
        let copy = try XCTUnwrap(copies.first)
        XCTAssertEqual(copy.copiedAt, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(
            try String(
                contentsOf: copy.directory.appendingPathComponent("luna_pinyin.userdb/000003.log"), encoding: .utf8),
            "second")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: copy.directory.appendingPathComponent("installation.yaml").path))
        try store.discardRawCopy(copy)
        XCTAssertEqual(try store.rawCopies(), [])
    }

    func testNoDatabasesMeansNoCopy() throws {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: user) }
        try store.saveRawCopy(sourceID: "scheme:a", revision: "r", sourceName: "A", userDirectory: user, now: Date())
        XCTAssertEqual(try store.rawCopies(), [])
    }
}
