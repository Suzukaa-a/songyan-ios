import XCTest

@testable import KeyboardCore

final class RimeSnapshotCollectorTests: XCTestCase {
    private func snapshot(_ name: String = "luna_pinyin", rows: Int = 2) -> Data {
        RimeUserDbTextTests.snapshot(name: name, rows: rows)
    }

    private func picked(_ name: String, _ data: Data) -> PickedFile {
        PickedFile(name: name) { limit in data.count > limit ? nil : data }
    }

    /// A stored (uncompressed) ZIP, so the tests need no tool to build one.
    static func storedZip(_ entries: [(String, Data)]) -> Data {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16(value >> 16 & 0xFFFF) }
        var body = Data()
        var directory = Data()
        for (name, data) in entries {
            let offset = body.count
            let nameBytes = Array(name.utf8)
            let crc = Int(BoundedZipReader.crc32(data))
            body.append(contentsOf: [0x50, 0x4B, 0x03, 0x04] + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0))
            body.append(contentsOf: le32(crc) + le32(data.count) + le32(data.count) + le16(nameBytes.count) + le16(0))
            body.append(contentsOf: nameBytes)
            body.append(data)
            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02] + le16(20) + le16(20) + le16(0x0800) + le16(0))
            directory.append(contentsOf: le16(0) + le16(0) + le32(crc) + le32(data.count) + le32(data.count))
            directory.append(contentsOf: le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0))
            directory.append(contentsOf: le32(offset))
            directory.append(contentsOf: nameBytes)
        }
        var end = Data([0x50, 0x4B, 0x05, 0x06])
        end.append(contentsOf: le16(0) + le16(0) + le16(entries.count) + le16(entries.count))
        end.append(contentsOf: le32(directory.count) + le32(body.count) + le16(0))
        return body + directory + end
    }

    // MARK: Single files

    func testSnapshotIsRecognisedByContentWhateverItsName() throws {
        let result = try RimeSnapshotCollector.collect(
            files: [picked("export.txt", snapshot()), picked("notes.txt", Data("hello".utf8))], byContent: true)
        XCTAssertEqual(result.snapshots.map(\.dictionary), ["luna_pinyin"])
        XCTAssertEqual(result.snapshots.first?.entryCount, 2)
        XCTAssertEqual(result.skipped, [SkippedSnapshot(fileName: "notes.txt", reason: .notASnapshot)])
    }

    func testBOMIsDroppedFromTheStagedData() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + snapshot()
        let result = try RimeSnapshotCollector.collect(files: [picked("a.userdb.txt", data)], byContent: true)
        XCTAssertEqual(result.snapshots.first?.data, snapshot())
    }

    func testEmptyAndDamagedAndTooLargeSnapshotsAreSkippedWithReasons() throws {
        var damaged = snapshot()
        damaged.append(contentsOf: [0xFF, 0xFE])
        let large = snapshot(rows: 1) + Data(repeating: 0x20, count: RimeSnapshotCollector.maximumFileBytes)
        let result = try RimeSnapshotCollector.collect(
            files: [
                picked("empty.userdb.txt", snapshot(rows: 0)),
                picked("damaged.userdb.txt", damaged),
                picked("large.userdb.txt", large),
                picked("noname.userdb.txt", RimeUserDbTextTests.snapshot(name: "")),
            ], byContent: true)
        XCTAssertTrue(result.snapshots.isEmpty)
        XCTAssertEqual(
            result.skipped.map(\.reason), [.empty, .notASnapshot, .tooLarge, .notASnapshot])
    }

    func testTooManyOrTooLargeAPickIsRefusedWhole() {
        let many = (0...RimeSnapshotCollector.maximumFiles).map { picked("f\($0).userdb.txt", snapshot()) }
        XCTAssertThrowsError(try RimeSnapshotCollector.collect(files: many, byContent: true)) {
            XCTAssertEqual($0 as? RimeSnapshotCollector.TooLarge, RimeSnapshotCollector.TooLarge())
        }
        let body = Data(repeating: 0x20, count: RimeSnapshotCollector.maximumFileBytes - 1_000)
        let big = (0..<3).map { picked("g\($0).userdb.txt", snapshot() + body) }
        XCTAssertThrowsError(try RimeSnapshotCollector.collect(files: big, byContent: true))
    }

    func testSeveralSnapshotsOfOneDictionaryAreAllKept() throws {
        let files = (0..<3).map { picked("p\($0).userdb.txt", snapshot()) }
        XCTAssertEqual(try RimeSnapshotCollector.collect(files: files, byContent: true).snapshots.count, 3)
    }

    // MARK: ZIP

    func testStoredZipYieldsOnlyUserdbEntriesAndSkipsMacosxAndHiddenFiles() throws {
        let zip = Self.storedZip([
            ("sync/home/luna_pinyin.userdb.txt", snapshot()),
            ("sync/home/installation.yaml", Data("a: b\n".utf8)),
            ("__MACOSX/sync/home/._luna_pinyin.userdb.txt", snapshot("junk")),
            ("sync/home/.hidden.userdb.txt", snapshot("hidden")),
            ("sync/home/", Data()),
        ])
        let result = try RimeSnapshotCollector.collect(files: [picked("sync.zip", zip)], byContent: true)
        XCTAssertEqual(result.snapshots.map(\.dictionary), ["luna_pinyin"])
        XCTAssertEqual(result.snapshots.first?.fileName, "luna_pinyin.userdb.txt")
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testDeflatedZipFromAnotherToolIsRead() throws {
        let base64 =
            "UEsDBBQAAAAIABEQYV3L/Ex61gAAAPwCAAAgAAAAc3luYy9ob21lL2x1bmFfcGlueWluLnVzZXJkYi50eHRl0TtuwlAUhOHarOJKLCDMmGeBxBqyAWRsF1cKNwhM4d2wEXaThYSccZOhOM0vneLTzNNnPvfpfuuvqcvtkL9Lcx1n88NHdzqW5txXX/fSHC+5jLlMeRgvffX30Z1mJS9S9fN8LKp2j9S9btjjVREVVhmVVuuotdVl1KXVVdSV1XXUtdVN1I3VbdSt1V3UnSuEw5tu4rkPAsKFEBFuhJBwJcSEOyEoXApR4VYIC9dCXLiX8tK9lJdve06Dupfy0r2Ul+6lvHQv5aV7KS/dS3npXsrL/95fUEsDBBQAAAAIABEQYV2XKXO2BwAAAAUAAAAbAAAAc3luYy9ob21lL2luc3RhbGxhdGlvbi55YW1sq7BSqOQCAFBLAQIUAxQAAAAIABEQYV3L/Ex61gAAAPwCAAAgAAAAAAAAAAAAAACAAQAAAABzeW5jL2hvbWUvbHVuYV9waW55aW4udXNlcmRiLnR4dFBLAQIUAxQAAAAIABEQYV2XKXO2BwAAAAUAAAAbAAAAAAAAAAAAAACAARQBAABzeW5jL2hvbWUvaW5zdGFsbGF0aW9uLnlhbWxQSwUGAAAAAAIAAgCXAAAAVAEAAAAA"
        let zip = try XCTUnwrap(Data(base64Encoded: base64))
        let result = try RimeSnapshotCollector.collect(files: [picked("x.zip", zip)], byContent: true)
        XCTAssertEqual(result.snapshots.map(\.dictionary), ["luna_pinyin"])
        XCTAssertEqual(result.snapshots.first?.entryCount, 30)
    }

    func testZipWithoutSnapshotsOrDamagedIsOneSkippedFile() throws {
        let noSnapshots = Self.storedZip([("a.txt", Data("x".utf8))])
        var damaged = Self.storedZip([("a.userdb.txt", snapshot())])
        damaged[damaged.startIndex + 60] ^= 0xFF  // inside the stored payload: the CRC no longer matches
        let truncated = Self.storedZip([("a.userdb.txt", snapshot())]).dropLast(10)
        let result = try RimeSnapshotCollector.collect(
            files: [picked("a.zip", noSnapshots), picked("b.zip", damaged), picked("c.zip", Data(truncated))],
            byContent: true)
        XCTAssertTrue(result.snapshots.isEmpty)
        XCTAssertEqual(result.skipped.map(\.fileName), ["a.zip", "b.zip", "c.zip"])
        XCTAssertEqual(Set(result.skipped.map(\.reason)), [.notASnapshot])
    }

    func testZipEntriesBeyondThreeLevelsAreIgnored() throws {
        let zip = Self.storedZip([
            ("a/b/c.userdb.txt", snapshot("three")),
            ("a/b/c/d.userdb.txt", snapshot("four")),
        ])
        let result = try RimeSnapshotCollector.collect(files: [picked("z.zip", zip)], byContent: true)
        XCTAssertEqual(result.snapshots.map(\.dictionary), ["three"])
    }

    func testZipEntryOverTheFileLimitIsSkippedAsTooLarge() throws {
        let large = snapshot() + Data(repeating: 0x20, count: RimeSnapshotCollector.maximumFileBytes)
        let zip = Self.storedZip([("big.userdb.txt", large), ("ok.userdb.txt", snapshot())])
        let result = try RimeSnapshotCollector.collect(files: [picked("z.zip", zip)], byContent: true)
        XCTAssertEqual(result.snapshots.count, 1)
        XCTAssertEqual(result.skipped, [SkippedSnapshot(fileName: "big.userdb.txt", reason: .tooLarge)])
    }

    func testZipIsNotOpenedWhenNotPickedByContent() throws {
        let zip = Self.storedZip([("a.userdb.txt", snapshot())])
        let result = try RimeSnapshotCollector.collect(files: [picked("z.userdb.txt", zip)], byContent: false)
        XCTAssertTrue(result.snapshots.isEmpty)
    }

    // MARK: Folders

    private struct Node: PickedNode {
        let name: String
        let kids: [Node]?
        var data = Data()
        var isDirectory: Bool { kids != nil }
        func children() throws -> [PickedNode] { kids ?? [] }
        func file() -> PickedFile { PickedFile(name: name) { _ in data } }
    }

    func testFolderWalkTakesOnlyUserdbFilesNotHiddenOrMacosxAtMostThreeLevelsDeep() throws {
        let tree = Node(
            name: "Rime",
            kids: [
                Node(name: "a.userdb.txt", kids: nil),
                Node(name: "installation.yaml", kids: nil),
                Node(name: ".b.userdb.txt", kids: nil),
                Node(name: "__MACOSX", kids: [Node(name: "m.userdb.txt", kids: nil)]),
                Node(
                    name: "sync",
                    kids: [
                        Node(
                            name: "home",
                            kids: [
                                Node(name: "c.USERDB.TXT", kids: nil),
                                Node(name: "deep", kids: [Node(name: "d.userdb.txt", kids: nil)]),
                            ])
                    ]),
            ])
        let names = try RimeSnapshotCollector.files(in: tree).map(\.name)
        XCTAssertEqual(names, ["a.userdb.txt", "c.USERDB.TXT"])
    }

    func testFolderWithTooManySnapshotsIsRefused() {
        let tree = Node(
            name: "Rime",
            kids: (0...RimeSnapshotCollector.maximumFiles).map { Node(name: "f\($0).userdb.txt", kids: nil) })
        XCTAssertThrowsError(try RimeSnapshotCollector.files(in: tree))
    }

    func testDiskFolderIsWalkedAndReadBounded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-" + UUID().uuidString, isDirectory: true)
        let inner = root.appendingPathComponent("sync/home", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try snapshot().write(to: inner.appendingPathComponent("luna_pinyin.userdb.txt"))
        try Data("x".utf8).write(to: inner.appendingPathComponent("installation.yaml"))
        try Data(repeating: 0x20, count: 100).write(to: root.appendingPathComponent("big.userdb.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.userdb.txt"),
            withDestinationURL: inner.appendingPathComponent("luna_pinyin.userdb.txt"))

        let node = try XCTUnwrap(DiskPickedNode(url: root))
        let files = try RimeSnapshotCollector.files(in: node)
        XCTAssertEqual(files.map(\.name), ["big.userdb.txt", "luna_pinyin.userdb.txt"])
        XCTAssertNil(try files[0].read(10))
        let result = try RimeSnapshotCollector.collect(files: files, byContent: false)
        XCTAssertEqual(result.snapshots.map(\.dictionary), ["luna_pinyin"])
        XCTAssertEqual(result.skipped, [SkippedSnapshot(fileName: "big.userdb.txt", reason: .notASnapshot)])
    }
}
