import XCTest

@testable import PackageManager

/// A script of the user's takes effect only after the user agreed to that script.
final class UserScriptsTests: XCTestCase {
    private var scripts: UserScripts!

    override func setUpWithError() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        scripts = UserScripts(state: UserConfigState(directory: state))
    }

    private func package(_ files: [String: String]) -> PackageFiles {
        let data = files.mapValues { Data($0.utf8) }
        return PackageFiles(hashes: data.mapValues(sha256Hex), read: { data[$0] })
    }

    private func files(_ values: [String: String]) -> [String: Data] { values.mapValues { Data($0.utf8) } }

    func testALuaFileAndALuaEntryAreScriptsButPlainPatchesAreNot() {
        let found = UserScripts.entries(
            files([
                "lua/date.lua": "return {}\n",
                "x.custom.yaml": "patch:\n  engine/filters/+: [lua_filter@*date]\n  menu/page_size: 5\n",
                "y.custom.yaml": "patch:\n  menu/page_size: 5\n",
                "words.txt": "lua_filter@x\n",
            ]), package: .none)
        XCTAssertEqual(found.map(\.id), ["lua/date.lua", "x.custom.yaml: lua_filter@*date"])
        XCTAssertEqual(found.map(\.path), ["lua/date.lua", "x.custom.yaml"])
    }

    func testWhatThePackageShipsItselfIsNotAskedAbout() {
        let source = package([
            "lua/own.lua": "return 1\n", "rime_ice.schema.yaml": "engine:\n  filters:\n    - lua_filter@*own\n",
        ])
        XCTAssertTrue(
            UserScripts.entries(
                files([
                    "lua/own.lua": "return 1\n",
                    "rime_ice.schema.yaml": "engine:\n  filters:\n    - lua_filter@*own\n",
                ]), package: source
            ).isEmpty)
        // Changed, or with one more entry, it is the user's.
        XCTAssertEqual(
            UserScripts.entries(
                files([
                    "lua/own.lua": "return 2\n",
                    "rime_ice.schema.yaml": "engine:\n  filters:\n    - lua_filter@*own\n    - lua_filter@*extra\n",
                ]), package: source
            ).map(\.id),
            ["lua/own.lua", "rime_ice.schema.yaml: lua_filter@*extra"])
    }

    func testAnAgreedScriptStaysAgreedUntilItChanges() {
        let first = files(["lua/a.lua": "return 1\n"])
        let pending = scripts.unconfirmed(first, package: .none)
        XCTAssertEqual(pending.map(\.id), ["lua/a.lua"])
        scripts.accept(pending)
        XCTAssertTrue(scripts.unconfirmed(first, package: .none).isEmpty)
        // The yes is to this content: a changed script is asked about again.
        XCTAssertEqual(scripts.unconfirmed(files(["lua/a.lua": "return 2\n"]), package: .none).map(\.id), ["lua/a.lua"])
        // And a script at another path is not covered by a yes to this one.
        XCTAssertEqual(scripts.unconfirmed(files(["lua/b.lua": "return 1\n"]), package: .none).map(\.id), ["lua/b.lua"])
    }

    func testUnreadableYamlIsLeftToTheOtherChecks() {
        XCTAssertTrue(UserScripts.entries(files(["x.custom.yaml": "patch: [lua_filter@x\n"]), package: .none).isEmpty)
    }

    func testTheRiskIsAcceptedOnceAndOnlyByAccepting() {
        XCTAssertFalse(scripts.riskAccepted())
        _ = scripts.unconfirmed(files(["lua/a.lua": "x"]), package: .none)
        XCTAssertFalse(scripts.riskAccepted())
        scripts.accept([UserScripts.Entry(id: "lua/a.lua", hash: "h")])
        XCTAssertTrue(scripts.riskAccepted())
    }

    func testADictionaryHeaderIsReadAndItsRowsAreNot() {
        let header = files(["w.dict.yaml": "---\nname: w\nengine: [lua_filter@*w]\n...\nlua_filter@*row\t1\n"])
        XCTAssertEqual(UserScripts.entries(header, package: .none).map(\.id), ["w.dict.yaml: lua_filter@*w"])
    }

    func testABareComponentNameAndATaggedOneAreScriptsToo() {
        let found = UserScripts.entries(
            files(["x.custom.yaml": "patch:\n  a: [lua_filter]\n  b: [!!null lua_translator@t]\n"]), package: .none)
        XCTAssertEqual(found.map(\.id), ["x.custom.yaml: lua_filter", "x.custom.yaml: lua_translator@t"])
    }

    func testAnEscapedSpellingOfAComponentIsStillOne() {
        let found = UserScripts.entries(
            files(["x.custom.yaml": "patch:\n  engine/filters/+: [\"\\x6Cua_filter@*x\"]\n"]), package: .none)
        XCTAssertEqual(found.map(\.id), ["x.custom.yaml: lua_filter@*x"])
    }

    func testConfirmedComponentsAreKnownByTheirContent() {
        let pending = scripts.unconfirmed(
            files(["x.custom.yaml": "patch:\n  engine/filters/+: [lua_filter@*mine]\n", "lua/a.lua": "return 1\n"]),
            package: .none)
        XCTAssertTrue(scripts.confirmedComponents().isEmpty)
        scripts.accept(pending)
        // A script file confirms itself, not a component.
        XCTAssertEqual(scripts.confirmedComponents(), ["lua_filter@*mine"])
        // A record whose hash is not its component's confirms nothing.
        scripts.accept([UserScripts.Entry(id: "y.custom.yaml: lua_filter@*forged", hash: "0000")])
        XCTAssertEqual(scripts.confirmedComponents(), ["lua_filter@*mine"])
    }

    func testShippedComponentsComeFromThePackagesOwnYamlAndNeverFromBuild() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("res-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("engine:\n  filters:\n    - lua_filter@*shipped\n".utf8).write(
            to: resources.appendingPathComponent("p.schema.yaml"))
        try Data("engine:\n  filters:\n    - lua_filter@*compiled\n".utf8).write(
            to: resources.appendingPathComponent("build/x.yaml"))
        XCTAssertEqual(CompiledConfigGuard.shippedComponents(resources: resources), ["lua_filter@*shipped"])
    }
}
