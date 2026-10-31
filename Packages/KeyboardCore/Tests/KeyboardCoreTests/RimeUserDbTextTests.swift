import XCTest

@testable import KeyboardCore

final class RimeUserDbTextTests: XCTestCase {
    static func snapshot(
        name: String = "luna_pinyin", type: String? = "userdb", extra: String = "", rows: Int = 2,
        lineEnd: String = "\n"
    ) -> Data {
        var lines = ["# Rime user dictionary", "#@/db_name\t\(name)"]
        if let type { lines.append("#@/db_type\t\(type)") }
        if !extra.isEmpty { lines.append(extra) }
        lines += (0..<rows).map { "ni\($0) \t你\($0)\tc=1 d=1 t=1" }
        return Data((lines.joined(separator: lineEnd) + lineEnd).utf8)
    }

    func testReadsDictionaryAndEntryCount() throws {
        let info = try RimeUserDbText.inspect(Self.snapshot(rows: 3))
        XCTAssertEqual(info, RimeUserDbSnapshotInfo(dictionary: "luna_pinyin", entryCount: 3))
    }

    func testRimeVersionUserIDAndTypeAreNotRequired() throws {
        XCTAssertEqual(try RimeUserDbText.inspect(Self.snapshot(type: nil)).dictionary, "luna_pinyin")
        let full = Self.snapshot(extra: "#@/rime_version\t1.8.5\n#@/user_id\tother\n#@/tick\t9")
        XCTAssertEqual(try RimeUserDbText.inspect(full).entryCount, 2)
    }

    func testUserdbSuffixIsStrippedLikeLibrime() throws {
        XCTAssertEqual(try RimeUserDbText.inspect(Self.snapshot(name: "luna_pinyin.userdb")).dictionary, "luna_pinyin")
        XCTAssertEqual(
            try RimeUserDbText.inspect(Self.snapshot(name: "luna_pinyin.userdb.kct")).dictionary, "luna_pinyin")
        XCTAssertEqual(RimeUserDbText.dictionaryName("a.b"), "a.b")
    }

    func testCRLFLineEndsAndBOMAreAccepted() throws {
        let windows = Self.snapshot(lineEnd: "\r\n")
        XCTAssertEqual(try RimeUserDbText.inspect(windows).entryCount, 2)
        let withBOM = Data([0xEF, 0xBB, 0xBF]) + windows
        XCTAssertTrue(RimeUserDbText.looksLikeSnapshot(withBOM.prefix(64)))
        XCTAssertEqual(try RimeUserDbText.inspect(withBOM).dictionary, "luna_pinyin")
        XCTAssertEqual(RimeUserDbText.strippingBOM(withBOM), windows)
    }

    func testRefusesWhatLibrimeWouldRefuse() {
        let text = String(decoding: Self.snapshot(), as: UTF8.self)
        let bad: [Data] = [
            Self.snapshot(type: "tabledb"),
            Self.snapshot(name: ""),
            Self.snapshot(name: ".hidden"),
            Self.snapshot(name: "a/b"),
            Data(text.replacingOccurrences(of: "#@/db_name\tluna_pinyin\n", with: "").utf8),
            Data("junk\n".utf8),
            Data(),
            Data(text.replacingOccurrences(of: "userdb\n", with: "userdb\n#@/db_type\tuserdb\n").utf8),
        ]
        for data in bad {
            XCTAssertThrowsError(try RimeUserDbText.inspect(data))
        }
    }

    func testRefusesNonUTF8() {
        var data = Self.snapshot()
        data.append(contentsOf: [0xFF, 0xFE, 0x0A])
        XCTAssertThrowsError(try RimeUserDbText.inspect(data))
    }

    func testRowsWithoutTwoFieldsAreNotEntries() throws {
        let data = Data("# Rime user dictionary\n#@/db_name\tx\n\nlonely\n \t\tc=1\nni \t你\tc=1\n".utf8)
        XCTAssertEqual(try RimeUserDbText.inspect(data).entryCount, 1)
    }

    func testLooksLikeSnapshotChecksOnlyTheHeader() {
        XCTAssertTrue(RimeUserDbText.looksLikeSnapshot(Data("# Rime user dictionary\n".utf8)))
        XCTAssertFalse(RimeUserDbText.looksLikeSnapshot(Data("# Rime user dict".utf8)))
        XCTAssertFalse(RimeUserDbText.looksLikeSnapshot(Data("{\"version\":1}".utf8)))
    }
}
