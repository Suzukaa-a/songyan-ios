import KeyboardCore
import XCTest

@testable import PackageManager

/// A layout's own grouping may put codes other than letters on a key; the companion folds them too.
final class CompactFoldCodesTests: XCTestCase {
    func testAMarkSharingALettersKeyFoldsOntoIt() throws {
        // The bundled 14-key grouping, plus `;` on the QW key.
        var map = CompactFold.merged14.map
        map[";"] = "q"
        let fold = try XCTUnwrap(CompactFold.of(kind: .merged14, map: map))
        let physical = try XCTUnwrap(
            CompactSchemaAdapter.physicalFold(sourceAlphabet: "abcdefghijklmnopqrstuvwxyz;", fold: fold))
        XCTAssertTrue(physical.rules.contains("derive/;/q/"), "\(physical.rules)")
        XCTAssertFalse(physical.ignoredCharacters.contains(";"))
        // Without it on a key, `;` is typed as itself, as before.
        let bundled = try XCTUnwrap(
            CompactSchemaAdapter.physicalFold(sourceAlphabet: "abcdefghijklmnopqrstuvwxyz;", fold: .merged14))
        XCTAssertFalse(bundled.rules.contains { $0.hasPrefix("derive/;") })
    }

    func testRegexCharactersAreEscaped() {
        XCTAssertEqual(CompactSchemaAdapter.deriveRule(code: ".", folded: "l"), "derive/\\./l/")
        XCTAssertEqual(CompactSchemaAdapter.deriveRule(code: "/", folded: "l"), "derive|\\/|l|")
        XCTAssertEqual(CompactSchemaAdapter.deriveRule(code: "'", folded: "q"), "derive/'/q/")
    }

    func testAGroupingOfItsOwnIsAGeneratedCompanion() throws {
        var map = CompactFold.merged14.map
        map["w"] = "e"
        map["e"] = "e"
        let fold = try XCTUnwrap(CompactFold.of(kind: .merged14, map: map))
        let id = CompactSchemaAdapter.identifier(sourceID: "pinyin", fold: fold)
        XCTAssertTrue(CompactSchemaAdapter.isGeneratedCompanionID(id), id)
    }
}
