import XCTest

@testable import SkinKit

final class SkinFormatV2Tests: XCTestCase {
    private func pngHeader(width: UInt32, height: UInt32) -> Data {
        func be(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> UInt32(24 - 8 * $0)) & 255) } }
        return Data(
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [0, 0, 0, 13] + Array("IHDR".utf8)
                + be(width) + be(height) + [1, 0, 0, 0, 0])
    }

    private func url(_ data: Data, type: String = "png") -> String {
        "data:image/\(type);base64," + data.base64EncodedString()
    }

    func testAlphaColourParsingAndOutput() throws {
        let colour = try XCTUnwrap(SkinColor(hex: "#abcdef80"))
        XCTAssertEqual(colour.hex, "#ABCDEF80")
        XCTAssertEqual(colour.alpha, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(SkinColor(hex: "#abcdef")?.hex, "#ABCDEF")
        XCTAssertEqual(SkinColor(hex: "#ABCDEFFF")?.hex, "#ABCDEFFF")
        for bad in ["#12345", "#1234567", "#+FFFFF", "#GG0000", "ABCDEF", "#ABCDEF8", "#ABCDEF800"] {
            XCTAssertNil(SkinColor(hex: bad), bad)
        }
    }

    func testTextContrastIsMeasuredAgainstTheKeyOverTheSystemSurface() throws {
        // A 20% black key over the light surface is light grey, so white text is flipped to black.
        let key = try XCTUnwrap(SkinColor(hex: "#00000033"))
        let white = try XCTUnwrap(SkinColor(hex: "#FFFFFF"))
        let light = SkinDefinition.systemSurface(dark: false)
        XCTAssertEqual(white.contrasting(on: key, over: light).hex, "#000000")
        // A faint white key over the dark surface stays dark, so white text is kept.
        let faint = try XCTUnwrap(SkinColor(hex: "#FFFFFF1A"))
        XCTAssertEqual(white.contrasting(on: faint, over: SkinDefinition.systemSurface(dark: true)).hex, "#FFFFFF")

        var skin = SkinDefinition(id: "alpha", name: "alpha")
        var variant = SkinDefinition.Variant()
        variant.colors = ["key": "#00000033", "text": "#FFFFFF"]
        skin.variants.light = variant
        XCTAssertEqual(skin.resolvedColors(dark: false)["text"]?.hex, "#000000")
    }

    func testTranslucentTextIsMeasuredAsComposited() throws {
        let key = try XCTUnwrap(SkinColor(hex: "#FFFFFF"))
        let faint = try XCTUnwrap(SkinColor(hex: "#00000033"))
        XCTAssertEqual(faint.contrasting(on: key).hex, "#000000")
        let strong = try XCTUnwrap(SkinColor(hex: "#000000E6"))
        XCTAssertEqual(strong.contrasting(on: key).hex, "#000000E6")
    }

    func testImageInspection() throws {
        // A complete one-bit PNG, 5000 x 1 pixels.
        let wide = "iVBORw0KGgoAAAANSUhEUgAAE4gAAAABAQAAAAAaanklAAAAD0lEQVR4nGNgGAWjgJ4AAAJyAAHq5ifDAAAAAElFTkSuQmCC"
        XCTAssertEqual(SkinDefinition.inspectImage(dataURL: "data:image/png;base64," + wide), .failure(.tooManyPixels))
        // A truncated file whose header claims a legal size is unreadable, not accepted.
        XCTAssertEqual(
            SkinDefinition.inspectImage(dataURL: url(pngHeader(width: 4, height: 4))), .failure(.unreadable))
        XCTAssertEqual(
            SkinDefinition.inspectImage(
                dataURL: url(Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 8)))),
            .failure(.badMagic))
        XCTAssertEqual(SkinDefinition.inspectImage(dataURL: "data:image/png;base64,@@@"), .failure(.badBase64))
        XCTAssertEqual(SkinDefinition.inspectImage(dataURL: "data:image/gif;base64,AAAA"), .failure(.malformedDataURL))
        XCTAssertEqual(SkinDefinition.inspectImage(dataURL: "data:image/png;base64,"), .failure(.malformedDataURL))
        // WebP needs RIFF....WEBP.
        var riff = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVE".utf8)
        XCTAssertEqual(SkinDefinition.inspectImage(dataURL: url(riff, type: "webp")), .failure(.badMagic))
        riff = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8)
        XCTAssertNotEqual(SkinDefinition.inspectImage(dataURL: url(riff, type: "webp")), .failure(.badMagic))
    }

    func testDecodedSizeLimitIsExactlyOneMebibyte() {
        var bytes = pngHeader(width: 1, height: 1)
        bytes.append(Data(repeating: 0, count: SkinDefinition.maximumImageBytes - bytes.count + 1))
        XCTAssertEqual(bytes.count, 1_048_577)
        XCTAssertEqual(SkinDefinition.inspectImage(dataURL: url(bytes)), .failure(.tooLarge))
        bytes.removeLast()
        // At the limit the size check passes; the bytes are not a decodable image.
        XCTAssertEqual(SkinDefinition.inspectImage(dataURL: url(bytes)), .failure(.unreadable))
    }
}
