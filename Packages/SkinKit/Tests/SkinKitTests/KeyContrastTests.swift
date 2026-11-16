import XCTest

@testable import SkinKit

final class KeyContrastTests: XCTestCase {
    private func color(_ hex: String) -> SkinColor { SkinColor(hex: hex)! }

    /// Regression: 松烟墨韵 over a pale green gradient left Shift and 123 the colour of the band.
    func testFunctionKeysPartFromAPaleGradient() {
        var colors = ["key": color("#FFFFFF"), "control": color("#DDE3DA")]
        let band = [color("#E6EDE3"), color("#C8D7CA")]
        let veil = KeyContrast.separate(&colors, from: band)
        let key = colors["key"]!, control = colors["control"]!
        XCTAssertNotNil(veil, "a white key cannot get whiter: the band takes a veil")
        for stop in band.map({ veil!.composited(over: $0) }) {
            XCTAssertGreaterThanOrEqual(key.contrast(on: stop), KeyContrast.keyAgainstBackground - 0.01)
            XCTAssertGreaterThanOrEqual(control.contrast(on: stop), KeyContrast.functionAgainstBackground - 0.01)
        }
        XCTAssertGreaterThanOrEqual(control.contrast(on: key), KeyContrast.functionAgainstKey - 0.01)
        XCTAssertLessThan(control.contrast(on: color("#000000")), color("#DDE3DA").contrast(on: color("#000000")),
            "on a light background the function keys go darker")
    }

    func testASkinThatAlreadySeparatesIsLeftAsAuthored() {
        let authored = ["key": color("#FFFFFF"), "control": color("#ADB2BC")]
        var colors = authored
        XCTAssertNil(KeyContrast.separate(&colors, from: [color("#3A3F48")]))
        XCTAssertEqual(colors, authored)
    }

    func testTranslucentFillsAreNotMoved() {
        let authored = ["key": color("#FFFFFF80"), "control": color("#DDE3DA")]
        var colors = authored
        KeyContrast.separate(&colors, from: [color("#E6EDE3")])
        XCTAssertEqual(colors, authored)
    }
}
