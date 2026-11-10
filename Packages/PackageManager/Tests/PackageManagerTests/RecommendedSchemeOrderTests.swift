import XCTest

@testable import PackageManager

final class RecommendedSchemeOrderTests: XCTestCase {
    func testTaiwanPrefersBopomofoThenCangjieWithoutHidingOtherEntries() {
        let ordered = RecommendedSchemeSource.ordered(preferredLanguages: ["zh-Hant-TW"])
        XCTAssertEqual(Array(ordered.prefix(2).map(\.id)), ["rime-bopomofo", "rime-cangjie"])
        XCTAssertEqual(Set(ordered.map(\.id)), Set(RecommendedSchemeSource.catalog.map(\.id)))
    }

    func testHongKongAndMacaoPreferTheirThreeInputMethods() {
        for tag in ["zh-HK", "zh-Hant-MO"] {
            let ordered = RecommendedSchemeSource.ordered(preferredLanguages: [tag])
            XCTAssertEqual(
                Array(ordered.prefix(3).map(\.id)), ["rime-cangjie", "rime-quick", "rime-cantonese"])
            XCTAssertEqual(ordered.count, RecommendedSchemeSource.catalog.count)
        }
    }

    func testOtherPrimaryLanguagesKeepTheExistingCatalogOrder() {
        for languages in [[String](), ["en-US"], ["fr-FR", "zh-TW"], ["zh-Hant"]] {
            XCTAssertEqual(
                RecommendedSchemeSource.ordered(preferredLanguages: languages), RecommendedSchemeSource.catalog)
        }
        XCTAssertEqual(Array(RecommendedSchemeSource.catalog.prefix(2).map(\.id)), ["rime-ice", "rime-wanxiang"])
    }

    func testJapanesePrefersJapaneseEntriesWithoutChangingTheOtherEntriesOrder() throws {
        let existing = try XCTUnwrap(RecommendedSchemeSource.catalog.first)
        let japanese = RecommendedSchemeSource(
            id: "japanese-fixture", nameKey: "fixture.name", detailKey: "fixture.detail",
            languageTag: "ja", archives: existing.archives, advertisedSchemaIDs: ["japanese_fixture"])
        let others = RecommendedSchemeSource.catalog.filter { $0.languageTag != "ja" }
        let ordered = RecommendedSchemeSource.ordered(preferredLanguages: ["ja-JP"], sources: others + [japanese])
        XCTAssertEqual(ordered.first?.id, japanese.id)
        XCTAssertEqual(Array(ordered.dropFirst()), others)
    }

    func testTraditionalEntriesDeclareTheirFullRequiredArchivesAndInputMethods() throws {
        // Upstream schemas reach each other through schema dependencies and imports, so every
        // entry carries the complete pinned archive closure (counts and compressed byte totals
        // are the reviewed values; a missing hop fails the native catalogue harness).
        let expected: [String: (schemas: [String], archives: Int, bytes: Int64)] = [
            "rime-bopomofo": (["bopomofo_tw", "bopomofo"], 5, 4_789_908),
            "rime-cangjie": (["cangjie5"], 4, 4_447_962),
            "rime-quick": (["quick5"], 5, 4_488_193),
            "rime-cantonese": (["jyut6ping3"], 7, 9_880_532),
        ]
        for (id, requirement) in expected {
            let source = try XCTUnwrap(RecommendedSchemeSource.catalog.first { $0.id == id }, id)
            XCTAssertEqual(source.advertisedSchemaIDs, requirement.schemas, id)
            XCTAssertEqual(source.archives.count, requirement.archives, id)
            XCTAssertEqual(source.archives.first?.id, id, id)
            XCTAssertTrue(source.archives.allSatisfy { !$0.licenses.isEmpty && $0.byteCountHint > 0 })
            XCTAssertTrue(source.archives.allSatisfy { $0.sha256.count == 64 && $0.url.scheme == "https" })
            XCTAssertEqual(source.byteCountHint, requirement.bytes, id)
            XCTAssertEqual(source.byteCountHint, source.archives.reduce(0) { $0 + $1.byteCountHint })
        }
    }

    /// Japanese is upstream's prebuilt kagiroi in one archive, first for a Japanese system.
    func testJapaneseIsUpstreamsPrebuiltKagiroiAndLeadsForJapanese() throws {
        let source = try XCTUnwrap(RecommendedSchemeSource.catalog.first { $0.id == "rime-kagiroi" })
        XCTAssertEqual(source.languageTag, "ja")
        XCTAssertEqual(source.advertisedSchemaIDs, ["kagiroi"])
        XCTAssertEqual(source.archives.count, 1)
        XCTAssertEqual(source.byteCountHint, 67_182_927)
        XCTAssertTrue(source.url.absoluteString.hasSuffix("/1c4cd914a92ec433e2c90436414d7d05eeded6c9"))
        XCTAssertEqual(source.archives[0].licenses.map(\.name), ["GPL-3.0", "Mozc"])
        XCTAssertEqual(
            RecommendedSchemeSource.ordered(preferredLanguages: ["ja-JP"]).first?.id, "rime-kagiroi")
    }

    /// Both bopomofo input methods are selectable, and the Taiwan one stays the entry point.
    func testBopomofoOffersBothInputMethodsWithTaiwanFirst() throws {
        let source = try XCTUnwrap(RecommendedSchemeSource.catalog.first { $0.id == "rime-bopomofo" })
        XCTAssertEqual(source.advertisedSchemaIDs, ["bopomofo_tw", "bopomofo"])
    }

    func testExistingPackagesKeepTheirOwnEnabledInputMethodList() {
        for source in RecommendedSchemeSource.catalog.prefix(2) {
            XCTAssertNil(source.advertisedSchemaIDs)
            XCTAssertEqual(source.archives.count, 1)
        }
    }
}
