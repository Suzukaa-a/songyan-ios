import XCTest

@testable import PackageManager

/// The compiled build files are the last place a file name can be caught, whatever patch produced it.
final class CompiledConfigGuardTests: XCTestCase {
    private var build: URL!

    override func setUpWithError() throws {
        build = FileManager.default.temporaryDirectory.appendingPathComponent("build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let directory = build!
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    private func write(_ text: String, _ name: String) throws {
        try Data(text.utf8).write(to: build.appendingPathComponent(name))
    }

    private func refusal(shipped: Set<String> = [], confirmed: Set<String> = []) -> UserConfigError? {
        do {
            try CompiledConfigGuard.check(build: build, shipped: shipped, confirmed: confirmed)
            return nil
        } catch { return error as? UserConfigError }
    }

    func testOrdinaryCompiledFilesPass() throws {
        try write("schema_list:\n  - schema: songyan_quanpin\nmenu:\n  page_size: 5\n", "default.yaml")
        try write(
            "schema:\n  schema_id: songyan_quanpin\n  dependencies: [luna]\ntranslator:\n  dictionary: songyan_basic\n  prism: songyan_quanpin\n  user_dict: songyan_shared\n  db_class: userdb\n",
            "songyan_quanpin.schema.yaml")
        try Data([0, 1, 2]).write(to: build.appendingPathComponent("songyan_quanpin.prism.bin"))
        XCTAssertNil(refusal())
    }

    func testAnUnsafeValueIsNamedWithItsFile() throws {
        try write("menu:\n  page_size: 5\n", "default.yaml")
        try write("translator:\n  user_dict: /var/mobile/Documents/Rime 配置/leak\n", "x.schema.yaml")
        let error = refusal()
        XCTAssertEqual(error?.file, "x.schema.yaml")
        XCTAssertEqual(error?.problem, .unsafeReference)
    }

    func testAValueBehindATagOrAnOperatorSpellingIsStillFound() throws {
        try write("translator:\n  dictionary: !!null ../../x\n", "a.schema.yaml")
        XCTAssertEqual(refusal()?.file, "a.schema.yaml")
        try FileManager.default.removeItem(at: build.appendingPathComponent("a.schema.yaml"))
        try write("translator/user_dict/=: ../x\n", "b.schema.yaml")
        XCTAssertEqual(refusal()?.file, "b.schema.yaml")
    }

    func testUnreadableCompiledYamlFailsClosed() throws {
        try write("a: [1\n", "bad.schema.yaml")
        XCTAssertEqual(refusal()?.problem, .invalidYAML)
    }

    func testALuaComponentMustBeShippedOrConfirmed() throws {
        try write("engine:\n  filters:\n    - lua_filter@*shipped\n    - lua_filter@*mine\n", "a.schema.yaml")
        XCTAssertEqual(refusal()?.problem, .unconfirmedScript)
        XCTAssertNil(refusal(shipped: ["lua_filter@*shipped"], confirmed: ["lua_filter@*mine"]))
        XCTAssertEqual(refusal(shipped: ["lua_filter@*shipped"])?.file, "a.schema.yaml")
    }
}
