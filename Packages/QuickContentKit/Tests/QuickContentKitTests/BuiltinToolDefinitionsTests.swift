import Foundation
import QuickContentKit
import XCTest

final class BuiltinToolDefinitionsTests: XCTestCase {
    func testExamplesUseFourLanguageNamesAndValidate() throws {
        let examples = BuiltinToolDefinitions.all()
        XCTAssertEqual(
            examples.map(\.id),
            [
                BuiltinToolDefinitions.simplificationID,
                BuiltinToolDefinitions.halfwidthID,
                BuiltinToolDefinitions.uppercaseID,
            ])
        XCTAssertEqual(examples.count, 3)
        for example in examples {
            XCTAssertEqual(Set(example.name.keys), Set(ToolDefinition.nameLanguageTags))
            XCTAssertFalse(example.name.values.contains { $0.isEmpty })
            XCTAssertNoThrow(try example.validate(), example.id)
        }
    }

    func testSimplificationUsesTheCallersOpenCCConfig() {
        for config in [OpenCCToolConfig.s2t, .s2twp, .t2s] {
            let tool = BuiltinToolDefinitions.simplification(config: config)
            XCTAssertEqual(tool.id, BuiltinToolDefinitions.simplificationID)
            XCTAssertEqual(tool.steps, [.opencc(config: config)])
        }
        let defaultExample = BuiltinToolDefinitions.all().first
        XCTAssertEqual(
            defaultExample?.steps,
            [.opencc(config: BuiltinToolDefinitions.defaultSimplificationConfig)])
    }

    func testWidthConvertsToHalfAndCaseUppercases() {
        let examples = BuiltinToolDefinitions.all()
        XCTAssertEqual(examples[1].steps, [.width(mode: .toHalf)])
        XCTAssertEqual(examples[2].steps, [.caseTransform(mode: .upper)])
    }

    func testIdentifiersFitTheFileFormat() throws {
        let identifiers = BuiltinToolDefinitions.all().map(\.id)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for identifier in identifiers {
            XCTAssertLessThanOrEqual(identifier.utf8.count, ToolDefinitionLimits.maximumIdentifierUTF8Bytes)
            XCTAssertTrue(
                identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        }
    }
}
