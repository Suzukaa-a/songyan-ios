import Foundation
import XCTest

@testable import LayoutKit

/// The Chinese and English 123 and symbol presets are one bilingual page each; their old IDs stay
/// readable. The assertions describe what the next launch reads from a stored catalog.
final class KeyboardPageRegistryTests: XCTestCase {
    private let retiredIDs = [
        "page.numeric.chinese", "page.numeric.english", "page.symbols.chinese", "page.symbols.english",
    ]

    /// A stored page the way the retired presets shipped.
    private func retiredCopy(_ id: String, _ name: String, kind: KeyboardPageKind, ascii: Bool)
        -> KeyboardPageDefinition
    {
        var page =
            kind == .numeric
            ? KeyboardPagePresets.numericRowsPage(ascii: ascii) : KeyboardPagePresets.symbolRowsPage(ascii: ascii)
        page.id = id
        page.name = name
        page.defaultSymbolMarks = ascii ? .ascii : .chinese
        return page
    }

    private func load(
        pages: [KeyboardPageDefinition], pageOrder: [String]? = nil, compositions: [String: KeyboardComposition]
    ) throws -> LayoutRegistry {
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
        }
        var catalog: [String: Any] = [
            "layouts": try json([BuiltinLayouts.qwerty26]), "pages": try json(pages),
            "compositions": try json(compositions),
        ]
        if let pageOrder { catalog["pageOrder"] = pageOrder }
        let data = try JSONSerialization.data(withJSONObject: catalog)
        return try JSONDecoder().decode(LayoutRegistry.self, from: data)
    }

    func testTheLibraryListsOneBilingualPagePerShapeAndNoRetiredPage() throws {
        let pages = try LayoutRegistry().pages
        XCTAssertTrue(pages.allSatisfy { !retiredIDs.contains($0.id) })
        XCTAssertEqual(
            pages.filter { $0.kind == .numeric }.map(\.id),
            [KeyboardPagePresets.numericAutomatic.id, KeyboardPagePresets.numericKeypad.id])
        XCTAssertEqual(
            pages.filter { $0.kind == .symbols }.map(\.id),
            [KeyboardPagePresets.symbolsSystem.id, KeyboardPagePresets.symbolsCategorized.id])
        XCTAssertNil(KeyboardPagePresets.numericAutomatic.defaultSymbolMarks)
        XCTAssertNil(KeyboardPagePresets.symbolsSystem.defaultSymbolMarks)
        XCTAssertEqual(KeyboardPagePresets.numericAutomatic.name, "自动 123")
        XCTAssertEqual(KeyboardPagePresets.symbolsSystem.name, "默认符号页")
    }

    func testAPairingThatNamesARetiredPageKeepsItsBranchOnTheMergedRows() throws {
        let stored = [
            retiredCopy("page.numeric.chinese", "中文 123", kind: .numeric, ascii: false),
            retiredCopy("page.numeric.english", "英文 123", kind: .numeric, ascii: true),
            retiredCopy("page.symbols.chinese", "中文符号", kind: .symbols, ascii: false),
            retiredCopy("page.symbols.english", "英文符号", kind: .symbols, ascii: true),
        ]
        let loaded = try load(
            pages: stored, pageOrder: retiredIDs + KeyboardPagePresets.all.map(\.id),
            compositions: [
                "quanpin:qwerty26": KeyboardComposition(
                    mainLayoutID: BuiltinLayouts.qwerty26.id, symbolPageID: "page.symbols.chinese",
                    numericPageID: "page.numeric.english")
            ])
        try loaded.validate()
        XCTAssertEqual(
            Set(loaded.pages.map(\.id)).intersection(retiredIDs), ["page.symbols.chinese", "page.numeric.english"],
            "an untouched stored copy no pairing names is dropped")
        let pairing = try XCTUnwrap(loaded.compositions["quanpin:qwerty26"])
        XCTAssertEqual(pairing.numericPageID, "page.numeric.english")
        XCTAssertEqual(pairing.symbolPageID, "page.symbols.chinese")
        XCTAssertEqual(loaded.page(id: "page.numeric.english")?.defaultSymbolMarks, .ascii)
        XCTAssertEqual(loaded.page(id: "page.symbols.chinese")?.defaultSymbolMarks, .chinese)
        XCTAssertEqual(
            loaded.page(id: "page.numeric.english")?.rows,
            KeyboardPagePresets.numericRowsPage(ascii: true).rows, "the pinned page carries the merged rows")
    }

    func testARetiredPageTheUserEditedStaysTheirOwn() throws {
        var edited = retiredCopy("page.symbols.english", "英文符号", kind: .symbols, ascii: true)
        edited.name = "我的英文符号"
        let loaded = try load(
            pages: [edited],
            compositions: [
                "quanpin:qwerty26": KeyboardComposition(
                    mainLayoutID: BuiltinLayouts.qwerty26.id, symbolPageID: edited.id)
            ])
        try loaded.validate()
        XCTAssertEqual(loaded.page(id: edited.id), edited)
        XCTAssertEqual(loaded.compositions["quanpin:qwerty26"]?.symbolPageID, edited.id)
        XCTAssertEqual(loaded.page(id: edited.id)?.defaultSymbolMarks, .ascii, "the pairing and branch are unchanged")
    }

    func testAnEditedRetiredPageKeepsItsPlaceInTheLibraryOrder() throws {
        var edited = retiredCopy("page.numeric.chinese", "中文 123", kind: .numeric, ascii: false)
        edited.name = "我的 123"
        let order = ["page.numeric.chinese", "page.numeric.english"] + KeyboardPagePresets.all.map(\.id)
        let loaded = try load(
            pages: [edited, retiredCopy("page.numeric.english", "英文 123", kind: .numeric, ascii: true)],
            pageOrder: order, compositions: [:])
        XCTAssertEqual(loaded.pages.first?.id, edited.id)
        XCTAssertFalse(loaded.pages.contains { $0.id == "page.numeric.english" })
    }

    func testTheRetiredPagesNoLongerReachTheWire() throws {
        let data = try JSONEncoder().encode(try LayoutRegistry())
        let text = String(decoding: data, as: UTF8.self)
        for id in retiredIDs { XCTAssertFalse(text.contains(id), id) }
    }
}
