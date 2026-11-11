import CandidateKit
import SkinKit
import XCTest

@testable import AppearanceKit

/// Format version 2: alpha colours, multi-stop gradients and image backgrounds.
final class AppearanceFormatV2Tests: XCTestCase {
    private func fixture(_ name: String, ext: String = "json") throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"), name)
        return try Data(contentsOf: url)
    }

    private func object(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture(name + ".songyanappearance")) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Edits `skin.variants.light.background` of the image fixture.
    private func imageDocument(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var document = try object("v2-image")
        var skin = document["skin"] as! [String: Any]
        var variants = skin["variants"] as! [String: Any]
        var light = variants["light"] as! [String: Any]
        var background = light["background"] as! [String: Any]
        edit(&background)
        light["background"] = background
        variants["light"] = light
        skin["variants"] = variants
        document["skin"] = skin
        return try data(document)
    }

    private func rejection(_ input: Data) -> String? {
        do {
            _ = try AppearanceDocument.decode(input)
            return nil
        } catch { return error.localizedDescription }
    }

    // MARK: - Round trips

    func testVersion1FixturesStayByteIdentical() throws {
        for name in ["v1-builtin-songyan", "v1-builtin-paper", "v1-gradient"] {
            let bytes = try fixture(name + ".songyanappearance")
            let document = try AppearanceDocument.decode(bytes)
            XCTAssertEqual(document.formatVersion, 1, name)
            XCTAssertEqual(try document.encoded(), bytes, name)
        }
    }

    func testVersion2FixturesRoundTrip() throws {
        for name in ["v2-alpha", "v2-gradient", "v2-image"] {
            let bytes = try fixture(name + ".songyanappearance")
            let document = try AppearanceDocument.decode(bytes)
            XCTAssertEqual(document.formatVersion, 2, name)
            XCTAssertEqual(document.skin.formatVersion, 2, name)
            XCTAssertEqual(document.candidateBar.formatVersion, 2, name)
            XCTAssertEqual(try AppearanceDocument.decode(document.encoded()), document, name)
            XCTAssertEqual(try document.encoded(), bytes, name)
        }
    }

    func testAlphaColoursKeepUpperCaseAndSyntax() throws {
        let alpha = try AppearanceDocument.decode(fixture("v2-alpha.songyanappearance", ext: "json"))
        XCTAssertEqual(alpha.skin.variants.light?.colors?["key"], "#FFFFFF99")
        XCTAssertEqual(alpha.skin.variants.dark?.colors?["control"], "#0000004D")
        let lower = try object("v2-alpha")
        var skin = lower["skin"] as! [String: Any]
        skin["variants"] = ["light": ["colors": ["key": "#abcdef80"]]]
        var edited = lower
        edited["skin"] = skin
        let decoded = try AppearanceDocument.decode(data(edited))
        XCTAssertEqual(decoded.skin.variants.light?.colors?["key"], "#ABCDEF80")
    }

    func testVersionFollowsFeaturesInUse() throws {
        var skin = SkinDefinition.systemDefault
        XCTAssertEqual(try AppearanceDocument(id: "plain", name: "Plain", skin: skin).encoded().isEmpty, false)
        XCTAssertEqual(AppearanceDocument(id: "plain", name: "Plain", skin: skin).normalized().formatVersion, 1)
        skin.variants.light?.colors?["key"] = "#FFFFFF80"
        let upgraded = AppearanceDocument(id: "plain", name: "Plain", skin: skin).normalized()
        XCTAssertEqual(upgraded.formatVersion, 2)
        XCTAssertEqual(upgraded.skin.formatVersion, 2)
        XCTAssertEqual(upgraded.candidateBar.formatVersion, 2)
        skin.variants.light?.colors?["key"] = "#FFFFFF"
        XCTAssertEqual(AppearanceDocument(id: "plain", name: "Plain", skin: skin).normalized().formatVersion, 1)
    }

    func testVersion1GradientShapeStaysValidInVersion2() throws {
        var document = try object("v2-image")
        var skin = document["skin"] as! [String: Any]
        skin["variants"] = [
            "light": [
                "background": ["type": "linearGradient", "from": "#102030", "to": "#A0B0C0", "direction": "vertical"],
                "colors": ["key": "#FFFFFF80"],
            ]
        ]
        document["skin"] = skin
        XCTAssertNil(rejection(try data(document)))
    }

    // MARK: - Rejections with precise paths

    func testVersion2FeaturesAreRejectedInVersion1Files() throws {
        var document = try object("v2-alpha")
        document["formatVersion"] = 1
        var skin = document["skin"] as! [String: Any]
        skin["formatVersion"] = 1
        var bar = document["candidateBar"] as! [String: Any]
        bar["formatVersion"] = 1
        document["skin"] = skin
        document["candidateBar"] = bar
        XCTAssertTrue(try XCTUnwrap(rejection(data(document))).contains("$.variants.light.colors.key"))

        // A version 1 document cannot hold a version 2 part.
        var mixed = document
        var v2Skin = skin
        v2Skin["formatVersion"] = 2
        mixed["skin"] = v2Skin
        XCTAssertTrue(try XCTUnwrap(rejection(data(mixed))).contains("$.skin.formatVersion"))

        // Image and multi-stop gradients, in a version 1 skin.
        for name in ["v2-image", "v2-gradient"] {
            var file = try object(name)
            file["formatVersion"] = 1
            var part = file["skin"] as! [String: Any]
            part["formatVersion"] = 1
            file["skin"] = part
            XCTAssertNotNil(rejection(try data(file)), name)
        }
    }

    func testImageBackgroundRejections() throws {
        let good = try fixture("v2-image.songyanappearance")
        XCTAssertNil(rejection(good))
        let png = try XCTUnwrap(
            (try object("v2-image")["skin"] as? [String: Any])
                .flatMap { ($0["variants"] as? [String: Any])?["light"] as? [String: Any] }
                .flatMap { ($0["background"] as? [String: Any])?["image"] as? String })
        let payload = String(png.dropFirst("data:image/png;base64,".count))
        let wide = String(decoding: try fixture("wide-5000px.png", ext: "b64"), as: UTF8.self)
        let jpegMagic = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]).base64EncodedString()
        let cases: [(String, (inout [String: Any]) -> Void, String)] = [
            ("bad magic", { $0["image"] = "data:image/png;base64," + jpegMagic }, "background.image"),
            ("type mismatch", { $0["image"] = "data:image/jpeg;base64," + payload }, "background.image"),
            ("not base64", { $0["image"] = "data:image/png;base64,!!!" }, "background.image"),
            ("5000 px wide", { $0["image"] = "data:image/png;base64," + wide }, "background.image"),
            ("not a data url", { $0["image"] = "https://example.com/a.png" }, "background.image"),
            ("gif", { $0["image"] = "data:image/gif;base64," + payload }, "background.image"),
            ("missing image", { $0.removeValue(forKey: "image") }, "background.image"),
            ("bad align", { $0["align"] = "left" }, "background.align"),
            ("missing align", { $0.removeValue(forKey: "align") }, "background.align"),
            ("stray colour", { $0["color"] = "#FFFFFF" }, "background"),
            ("unknown field", { $0["fit"] = "cover" }, "background.fit"),
        ]
        for (name, edit, path) in cases {
            let message = try XCTUnwrap(rejection(imageDocument(edit)), name)
            XCTAssertTrue(message.contains(path), "\(name): \(message)")
        }
    }

    func testGradientRejections() throws {
        let base = try fixture("v2-gradient.songyanappearance")
        XCTAssertNil(rejection(base))
        func gradient(_ background: [String: Any]) throws -> Data {
            var document = try object("v2-gradient")
            var skin = document["skin"] as! [String: Any]
            skin["variants"] = ["light": ["background": background]]
            document["skin"] = skin
            return try data(document)
        }
        let five = ["#000000", "#111111", "#222222", "#333333", "#444444"]
        let cases: [(String, [String: Any], String)] = [
            ("5 colours", ["type": "linearGradient", "colors": five, "direction": "vertical"], "background.colors"),
            (
                "1 colour", ["type": "linearGradient", "colors": ["#000000"], "direction": "vertical"],
                "background.colors"
            ),
            (
                "bad stop", ["type": "linearGradient", "colors": ["#000000", "red"], "direction": "vertical"],
                "background.colors[1]"
            ),
            (
                "bad direction", ["type": "linearGradient", "colors": ["#000000", "#FFFFFF"], "direction": "radial"],
                "background.direction"
            ),
            (
                "mixed forms",
                [
                    "type": "linearGradient", "colors": ["#000000", "#FFFFFF"], "from": "#000000", "to": "#FFFFFF",
                    "direction": "vertical",
                ], "background"
            ),
            (
                "v1 form is vertical only",
                ["type": "linearGradient", "from": "#000000", "to": "#FFFFFF", "direction": "horizontal"],
                "background.direction"
            ),
            ("unknown type", ["type": "radial"], "background.type"),
        ]
        for (name, background, path) in cases {
            let message = try XCTUnwrap(rejection(gradient(background)), name)
            XCTAssertTrue(message.contains(path), "\(name): \(message)")
        }
    }

    func testUnsupportedVersionsAreRejected() throws {
        for version in [0, 3] {
            var document = try object("v2-alpha")
            document["formatVersion"] = version
            XCTAssertNotNil(rejection(try data(document)), "\(version)")
        }
    }

    // MARK: - Size limits

    func testDocumentSizeLimits() throws {
        // Trailing whitespace is valid JSON: it pads a file to a given size without changing content.
        func padded(_ bytes: Data, to size: Int) -> Data { bytes + Data(repeating: 0x20, count: size - bytes.count) }
        let alpha = try fixture("v2-alpha.songyanappearance")
        XCTAssertNil(rejection(padded(alpha, to: 256 * 1024)))
        XCTAssertNotNil(rejection(padded(alpha, to: 256 * 1024 + 1)))
        let image = try fixture("v2-image.songyanappearance")
        XCTAssertNil(rejection(padded(image, to: 256 * 1024 + 1)))
        XCTAssertNil(rejection(padded(image, to: 2_097_152)))
        XCTAssertNotNil(rejection(padded(image, to: 2_097_152 + 1)))
        // The candidate bar part keeps its own limit.
        XCTAssertThrowsError(
            try CandidateBarDefinition.decode(
                Data(#"{"formatVersion":2,"id":"x","name":"x"}"#.utf8) + Data(repeating: 0x20, count: 129 * 1024)))
    }

    func testImportedImageFileAboveVersion1LimitIsAccepted() throws {
        let image = try fixture("v2-image.songyanappearance")
        let padded = image + Data(repeating: 0x20, count: 300 * 1024)
        XCTAssertEqual(try AppearanceDocument.decodeImported(padded).formatVersion, 2)
    }

    // MARK: - Store

    func testStoreSavesListsAppliesAndReadsAnImageDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearance-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppearanceStore(directory: directory)
        let original = try fixture("v2-image.songyanappearance")
        let document = try AppearanceDocument.decode(original)
        try store.save(document)
        XCTAssertEqual(try store.catalog().documents.last, document)
        XCTAssertTrue(try store.catalog().unreadable.isEmpty)
        // Export writes the stored document: identical bytes.
        let stored = try Data(contentsOf: directory.appendingPathComponent("v2-image.songyanappearance.json"))
        XCTAssertEqual(stored, original)
        try store.apply(document)
        XCTAssertEqual(try store.readSnapshot().document, document)
        XCTAssertEqual(store.read().source, .applied)
        let snapshot = try String(contentsOf: directory.appendingPathComponent("active.json"), encoding: .utf8)
        XCTAssertFalse(snapshot.contains("\\/"))
    }

    func testSnapshotReadSkipsImagePayloadButKeepsShapeChecks() throws {
        let document = try AppearanceDocument.decode(fixture("v2-image.songyanappearance"))
        var corrupt = document
        corrupt.skin.variants.light?.background?.image = "data:image/png;base64,AAAA"
        XCTAssertThrowsError(try AppearanceDocument.decode(corrupt.encoded()))
        let bytes = try JSONEncoder().encode(corrupt)
        XCTAssertNoThrow(try AppearanceDocument.decode(bytes, verifyImage: false))
        corrupt.skin.variants.light?.background?.image = "nothing"
        XCTAssertThrowsError(try AppearanceDocument.decode(JSONEncoder().encode(corrupt), verifyImage: false))
    }
}
