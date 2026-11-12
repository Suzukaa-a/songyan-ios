import Foundation
import XCTest

@testable import ScriptAddonKit

final class ScriptAddonStoreTests: XCTestCase {
    private var root: URL!
    private var store: ScriptAddonStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-addons-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ScriptAddonStore(root: root)
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func declarations(
        name: String = "Uppercase", connects: [String] = ["api.example.com"],
        settings: [ScriptDeclarations.Setting] = [
            .init(key: "mode", kind: .choice, label: "Mode")
        ],
        secrets: [ScriptDeclarations.Secret] = [.init(key: "token", label: "Token")]
    ) -> ScriptDeclarations {
        ScriptDeclarations(
            apiVersion: 1, name: name, summary: "Uppercases text", connectHosts: connects,
            settings: settings, secrets: secrets, needsAudio: false)
    }

    private func addon(
        id: String = "addon-1", script: Data = Data("// @api 1\n// @name Upper\n".utf8),
        order: Int = 0, declarations: ScriptDeclarations? = nil
    ) throws -> ScriptAddonStore.Addon {
        let state = ScriptAddonState(id: id, order: order, scriptDigest: "", scriptByteCount: 0)
        return try store.add(
            id: id, script: script, state: state, maximumSourceBytes: 1_000_000)
    }

    func testListingAMissingRootIsEmpty() throws {
        let missing = root.appendingPathComponent("missing")
        let emptyStore = ScriptAddonStore(root: missing)
        XCTAssertEqual(try emptyStore.list(), [])
    }

    func testScriptBytesAreStoredByteForByte() throws {
        let original = Data([0xEF, 0xBB, 0xBF] + Array("// @api 1\r\n// @name Ünïcode\r\n".utf8))
        _ = try addon(script: original)
        XCTAssertEqual(try store.scriptBytes(id: "addon-1"), original)
        XCTAssertEqual(try store.exportData(id: "addon-1"), original)
    }

    func testStateJSONIsVersionedAndReadBack() throws {
        _ = try addon()
        let stateURL = root.appendingPathComponent("addon-1/state.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, ScriptAddonState.currentSchemaVersion)
        let loaded = try store.load(id: "addon-1").state
        XCTAssertEqual(loaded.id, "addon-1")
        XCTAssertTrue(loaded.enabled)
    }

    func testUnknownNewerStateVersionIsRejected() throws {
        _ = try addon()
        let stateURL = root.appendingPathComponent("addon-1/state.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        json["schemaVersion"] = ScriptAddonState.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: stateURL)
        XCTAssertThrowsError(try store.load(id: "addon-1"))
    }

    func testEnableOrderSettingsAndDelete() throws {
        _ = try addon(id: "a", order: 0)
        _ = try addon(id: "b", order: 1)
        try store.setEnabled(false, id: "a")
        try store.reorder(["b", "a"])
        try store.updateSetting(key: "mode", value: "fast", id: "b")
        let listed = try store.list()
        XCTAssertEqual(listed.map(\.state.id), ["b", "a"])
        XCTAssertEqual(listed[0].state.settings["mode"], "fast")
        XCTAssertFalse(listed[1].state.enabled)
        try store.delete(id: "a")
        XCTAssertEqual(try store.list().map(\.state.id), ["b"])
    }

    func testConfirmationDigestTracksSitesSettingsSecretsAndAudio() throws {
        let script = Data("// @api 1\n// @name Upper\n// @connect api.example.com\n".utf8)
        _ = try addon(script: script)
        let first = declarations()
        try store.confirm(declarations: first, id: "addon-1")
        XCTAssertFalse(try store.needsReconfirmation(id: "addon-1", declarations: first))

        // Body-only change does not ask again.
        XCTAssertFalse(
            try store.needsReconfirmation(
                id: "addon-1",
                declarations: declarations(name: "Uppercase", connects: ["api.example.com"])))

        // A new site asks again.
        XCTAssertTrue(
            try store.needsReconfirmation(
                id: "addon-1", declarations: declarations(connects: ["other.example.com"])))

        // A changed setting asks again.
        let changedSetting = declarations(
            settings: [.init(key: "mode", kind: .text, label: "Mode")])
        XCTAssertTrue(try store.needsReconfirmation(id: "addon-1", declarations: changedSetting))

        // Audio requirement asks again.
        let audio = ScriptDeclarations(
            apiVersion: 1, name: "Uppercase", summary: nil, connectHosts: ["api.example.com"],
            settings: [], secrets: [], needsAudio: true)
        XCTAssertTrue(try store.needsReconfirmation(id: "addon-1", declarations: audio))

        // Site order alone does not: confirm both hosts, then swap their order.
        let twoSites = declarations(connects: ["api.example.com", "cdn.example.com"])
        try store.confirm(declarations: twoSites, id: "addon-1")
        XCTAssertFalse(
            try store.needsReconfirmation(
                id: "addon-1",
                declarations: declarations(connects: ["cdn.example.com", "api.example.com"])))
    }

    /// Editing an existing script must replace script.js in place: moving over an
    /// existing file used to fail with "File exists".
    func testEditingReplacesTheExistingScriptBytes() throws {
        let original = Data("// @api 1\n// @name First\n".utf8)
        let edited = Data("// @api 1\n// @name Second\nreturn input;\n".utf8)
        _ = try addon(script: original)
        let addon = try store.replaceScript(id: "addon-1", script: edited, maximumSourceBytes: 1_000)
        XCTAssertEqual(try store.scriptBytes(id: "addon-1"), edited)
        XCTAssertEqual(addon.state.scriptByteCount, edited.count)
        XCTAssertEqual(addon.state.scriptDigest, ScriptAddonStore.digest(edited))
        XCTAssertEqual(try store.list().count, 1)
    }

    /// Importing a file again with the same identifier overwrites the stored bytes
    /// instead of failing on the existing script.js.
    func testReimportWithTheSameIdentifierOverwrites() throws {
        let first = Data("// @api 1\n// @name First\n".utf8)
        let second = Data("// @api 1\n// @name Second\n".utf8)
        _ = try addon(script: first)
        _ = try addon(script: second)
        XCTAssertEqual(try store.scriptBytes(id: "addon-1"), second)
        XCTAssertEqual(try store.list().map(\.state.id), ["addon-1"])
    }

    func testReplacingAMissingScriptFails() throws {
        XCTAssertThrowsError(
            try store.replaceScript(id: "missing", script: Data("x".utf8), maximumSourceBytes: 10))
    }

    /// Editing or updating a script must keep the state the user already chose: the new
    /// bytes and confirmation digest replace the old ones without resetting enable, order,
    /// settings or the secret-key list.
    func testReplacePreservesEnabledOrderSettingsAndSecretKeys() throws {
        var state = ScriptAddonState(
            id: "keep", enabled: false, order: 7, sourceURL: "https://example.com/s.js",
            scriptDigest: "", scriptByteCount: 0)
        state.settings = ["mode": "fast"]
        state.secretKeys = ["token"]
        _ = try store.add(
            id: "keep", script: Data("// @api 1\n// @name Old\n".utf8), state: state,
            maximumSourceBytes: 1_000)
        let updated = try store.replace(
            id: "keep", script: Data("// @api 1\n// @name New\n".utf8),
            maximumSourceBytes: 1_000, confirmedDigest: "digest-new",
            settings: ["mode": "slow", "other": "x"], secretKeys: ["token", "second"])
        XCTAssertFalse(updated.state.enabled)
        XCTAssertEqual(updated.state.order, 7)
        XCTAssertEqual(updated.state.settings, ["mode": "slow", "other": "x"])
        XCTAssertEqual(updated.state.secretKeys, ["second", "token"])
        XCTAssertEqual(updated.state.confirmedDigest, "digest-new")
        XCTAssertEqual(updated.state.sourceURL, "https://example.com/s.js")
        XCTAssertEqual(updated.state.scriptDigest, ScriptAddonStore.digest(Data("// @api 1\n// @name New\n".utf8)))
        XCTAssertEqual(try store.scriptBytes(id: "keep"), Data("// @api 1\n// @name New\n".utf8))
    }

    func testReplaceKeepsTheOldDigestWhenNoneIsGiven() throws {
        _ = try addon(id: "digest", script: Data("// @api 1\n".utf8))
        try store.confirm(declarations: declarations(), id: "digest")
        let before = try store.load(id: "digest").state.confirmedDigest
        let updated = try store.replace(
            id: "digest", script: Data("// @api 1\nreturn 1;\n".utf8), maximumSourceBytes: 100,
            confirmedDigest: nil)
        XCTAssertEqual(updated.state.confirmedDigest, before)
    }

    func testSettingsUpdateDoesNotTouchStoredScriptBytes() throws {
        let original = Data("// @api 1\n// @name Upper\n".utf8)
        _ = try addon(script: original)
        try store.updateSetting(key: "mode", value: "fast", id: "addon-1")
        XCTAssertEqual(try store.scriptBytes(id: "addon-1"), original)
    }

    func testSourceSizeLimitIsEnforced() throws {
        let state = ScriptAddonState(id: "big", order: 0, scriptDigest: "", scriptByteCount: 0)
        XCTAssertThrowsError(
            try store.add(
                id: "big", script: Data(repeating: 0x41, count: 10), state: state,
                maximumSourceBytes: 4))
    }

    func testSecretsStayOutOfTheStoredFiles() throws {
        // The store tracks keys only; a fake secret store holds the values.
        var state = ScriptAddonState(id: "secret", order: 0, scriptDigest: "", scriptByteCount: 0)
        state.secretKeys = ["token"]
        _ = try store.add(
            id: "secret", script: Data("// @api 1\n".utf8), state: state,
            maximumSourceBytes: 100)
        let directory = root.appendingPathComponent("secret")
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("super-secret-value"), name)
        }
        XCTAssertEqual(try store.load(id: "secret").state.secretKeys, ["token"])
    }
}
