import Foundation
import XCTest

@testable import PackageManager

/// A package's Lua components are discovered by reading its Lua sources. Only a real `require` names
/// a dependency: comments and string literals are plain text and must not manufacture a missing
/// module. The other direction matters as much: a real `require` written with whitespace, comments or
/// parentheses between its tokens is still a dependency, and a module path that leaves `lua/` stays
/// refused.
final class LuaDependencyScanningTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lua-dependency-scanning-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let directory = scratch!
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    func testFakeRequiresInCommentsAndStringsAreNotDependencies() throws {
        let helper = """
            -- require("fake/line-comment")
            --[[ require("fake/long-comment") ]]
            --[=[ require("fake/long-bracket-comment") ]=]
            --[==[ require("fake/level-two-comment") ]==]
            local text = "require('fake/normal-string')"
            local escaped = "an escaped quote \\"require('fake/escaped-string')\\""
            local long = [[require("fake/long-string")]]
            local longer = [=[require("fake/long-bracket-string")]=]
            local longest = [==[require("fake/level-two-string")]==]
            return {}
            """
        let package = try write(Self.package(helper: helper), to: "fake-requires")

        XCTAssertNoThrow(try manager().prepareSchemeImport(directory: package))
    }

    func testARealRequireWithCommentsWhitespaceAndParenthesesResolvesItsModule() throws {
        let helper = """
            local first = require --[[ between ]] ( "lexing/first" )
            local second = require
              ( 'lexing/second' )
            local third = require --[=[ bracket ]=] ( "lexing/second" )
            return { first, second, third }
            """
        let package = try write(Self.package(helper: helper), to: "real-requires")

        XCTAssertNoThrow(try manager().prepareSchemeImport(directory: package))
    }

    func testARealRequireWrittenWithCommentsAndParenthesesIsStillReportedWhenMissing() throws {
        let helper = """
            local block = require --[[ between ]] ( "lexing/missing-block" )
            local line = require -- between
              ( "lexing/missing-line" )
            return { block, line }
            """
        let package = try write(Self.package(helper: helper), to: "missing-requires")

        XCTAssertThrowsError(try manager().prepareSchemeImport(directory: package)) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("lua/lexing/missing-block.lua"),
                "a require after a long comment names its module: \(message)")
            XCTAssertTrue(
                message.contains("lua/lexing/missing-line.lua"),
                "a require after a line comment names its module: \(message)")
        }
    }

    func testARealRequireAfterAStringWithDashesAndAShortCommentIsStillReported() throws {
        let helper = """
            local separator = "--"
            --[ require("fake/not-a-long-comment")
            local missing = require("lexing/missing-after-string")
            return { separator, missing }
            """
        let package = try write(Self.package(helper: helper), to: "dash-string")

        XCTAssertThrowsError(try manager().prepareSchemeImport(directory: package)) { error in
            XCTAssertTrue(
                String(describing: error).contains("lua/lexing/missing-after-string.lua"),
                "a dash inside a string is not a comment: \(error)")
        }
    }

    func testAModulePathThatLeavesLuaIsStillRefused() throws {
        let helper = """
            local escaped = require("../escape")
            return { escaped }
            """
        let package = try write(Self.package(helper: helper), to: "unsafe-module")

        XCTAssertThrowsError(try manager().prepareSchemeImport(directory: package)) { error in
            XCTAssertTrue(
                String(describing: error).contains("依赖项路径非法"),
                "an unsafe module path is refused as before: \(error)")
        }
    }

    /// One schema that mounts a Lua component, so the helper module is actually read.
    private static func package(helper: String) -> [String: Data] {
        [
            "default.yaml": Data("schema_list:\n  - schema: lexing\n".utf8),
            "lexing.schema.yaml": Data(
                """
                schema:
                  schema_id: lexing
                  name: Lexing
                engine:
                  translators:
                    - lua_translator@*lexing/helper
                """.utf8),
            "lua/lexing/helper.lua": Data(helper.utf8),
            "lua/lexing/first.lua": Data("return {}\n".utf8),
            "lua/lexing/second.lua": Data("return {}\n".utf8),
        ]
    }

    private func manager() -> RecipePackageManager {
        RecipePackageManager(rootURL: scratch.appendingPathComponent("store-" + UUID().uuidString))
    }

    @discardableResult
    private func write(_ files: [String: Data], to name: String) throws -> URL {
        let directory = scratch.appendingPathComponent(name)
        for (path, data) in files {
            let destination = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }
        return directory
    }
}
