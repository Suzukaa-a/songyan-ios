import XCTest

@testable import LayoutKit

final class LayoutBottomRowTests: XCTestCase {
    func testBundledBoardsKeepTheKeyboardsOwnBottomRow() {
        for layout in [
            BuiltinLayouts.qwerty26, BuiltinLayouts.merged14, BuiltinLayouts.merged18, BuiltinLayouts.zhuyin41,
            BuiltinLayouts.cangjie26,
        ] {
            XCTAssertEqual(LayoutBottomRow.index(layout), layout.rows.count - 1, layout.id)
            XCTAssertNil(LayoutBottomRow.authored(layout), layout.id)
        }
    }

    func testTheEditorOpensTheKeyboardsRowAndAnUnchangedRowIsStoredAsBefore() {
        let layout = BuiltinLayouts.qwerty26.copy()
        let editable = LayoutBottomRow.editable(layout)
        XCTAssertEqual(editable.rows.last?.keys, LayoutBottomRow.defaultKeys)
        XCTAssertEqual(editable.rows.dropLast(), layout.rows.dropLast())
        XCTAssertEqual(LayoutBottomRow.storable(editable), layout)
    }

    /// The keyboard's own row types "，"; opening it in the editor, or storing an edit of it, must not
    /// cost the 26/14/18-key frame its Shift, Delete and separator.
    func testAnEditableOrEditedBottomRowKeepsTheShell() {
        for (layout, kind) in [
            (BuiltinLayouts.qwerty26, LayoutInput.Builtin.qwerty26), (BuiltinLayouts.merged14, .merged14),
            (BuiltinLayouts.merged18, .merged18),
        ] {
            let editable = LayoutBottomRow.editable(layout.copy())
            XCTAssertTrue(editable.rows.last!.keys.contains { $0.action.type == .literal }, layout.id)
            XCTAssertTrue(BuiltinLayouts.matchesMainShell(editable, as: kind), layout.id)
            var keys = LayoutBottomRow.defaultKeys
            keys.removeAll { $0.action.type == .globe }
            let edited = LayoutBottomRow.storable(LayoutBottomRow.replacing(keys, in: editable))
            XCTAssertNotNil(LayoutBottomRow.authored(edited), layout.id)
            XCTAssertTrue(BuiltinLayouts.matchesMainShell(edited, as: kind), layout.id)
        }
        // A fourth row that types engine input is not a bottom row: the shell would drop it.
        var encoding = BuiltinLayouts.qwerty26.copy()
        encoding.rows[3] = encoding.rows[0]
        XCTAssertFalse(BuiltinLayouts.matchesMainShell(encoding, as: .qwerty26))
    }

    func testTheKeyboardsRowStartsWith123AndTheGlobe() {
        let actions = LayoutBottomRow.defaultKeys.map(\.action)
        XCTAssertEqual(actions.first?.pageSwitchTarget, .numeric)
        XCTAssertEqual(actions.dropFirst().first?.type, .globe)
        XCTAssertTrue(actions.contains { $0.type == .space })
    }

    func testAnAddedSymbolKeyIsKeptAsAuthored() {
        let editable = LayoutBottomRow.editable(BuiltinLayouts.qwerty26.copy())
        var keys = LayoutBottomRow.defaultKeys
        keys.insert(LayoutKey(label: "符号", action: .pageSwitch(.symbols), titleMode: .automatic), at: 1)
        let edited = LayoutBottomRow.storable(LayoutBottomRow.replacing(keys, in: editable))
        XCTAssertEqual(LayoutBottomRow.authored(edited), keys)
        XCTAssertEqual(edited.rows.count, BuiltinLayouts.qwerty26.rows.count)
    }

    func testARowWithoutItsSpaceKeyIsStillTheBottomRow() {
        var keys = LayoutBottomRow.defaultKeys
        keys.removeAll { $0.action.type == .space }
        let edited = LayoutBottomRow.replacing(keys, in: BuiltinLayouts.qwerty26.copy())
        XCTAssertEqual(LayoutBottomRow.index(edited), edited.rows.count - 1)
        XCTAssertEqual(LayoutBottomRow.authored(edited), keys)
    }

    func testALetterRowIsNeverTheBottomRow() {
        let layout = LayoutDefinition(
            id: "letters", name: "letters", input: .init(),
            rows: [LayoutRow(keys: [LayoutKey(label: "a", action: .init(.code, value: "a"))])])
        XCTAssertNil(LayoutBottomRow.index(layout))
        XCTAssertNil(LayoutBottomRow.authored(layout))
        XCTAssertEqual(LayoutBottomRow.editable(layout), layout)
    }

    func testTheNineKeyPadKeepsItsOwnRows() {
        let layout = BuiltinLayouts.phone9.copy()
        XCTAssertEqual(LayoutBottomRow.editable(layout), layout)
    }

    func testAnAddedKeyTakesItsRoomFromTheSpaceBar() {
        let policy = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: false, isPhoneLayout: false, usesASCIIPunctuation: false)
        var keys = LayoutBottomRow.defaultKeys.filter { $0.action.type != .globe }
        let plain = KeyboardPageFooterGeometry(width: 390, keys: keys, policy: policy)
        XCTAssertTrue(plain.usesControlRowBudget)
        keys.insert(LayoutKey(label: "符号", action: .pageSwitch(.symbols), titleMode: .automatic), at: 1)
        let sized = KeyboardPageFooterGeometry(width: 390, keys: keys, policy: policy)
        let space = keys.firstIndex { $0.action.type == .space }!
        XCTAssertEqual(sized.keyWidths[space] + sized.keyWidths[1] + sized.spacing, plain.keyWidths[space - 1])
        XCTAssertTrue(sized.keyWidths.allSatisfy { $0 >= 44 })
        XCTAssertEqual(sized.keyWidths[0], plain.keyWidths[0])
        XCTAssertEqual(sized.keyWidths.reduce(0, +) + sized.spacing * Double(keys.count - 1), 390, accuracy: 0.001)
    }

    func testAChosenWidthKeepsTheAuthorsWeights() {
        let policy = KeyboardControlPolicy(
            page: .letters, isEnglishMode: false, hasGlobe: false, isPhoneLayout: false, usesASCIIPunctuation: false)
        var keys = LayoutBottomRow.defaultKeys.filter { $0.action.type != .globe }
        keys[0].width = 2
        XCTAssertFalse(KeyboardPageFooterGeometry(width: 390, keys: keys, policy: policy).usesControlRowBudget)
    }
}
