import XCTest

@testable import KeyboardCore

/// Which layouts a jump key may switch to: the running one and those the running schema has a
/// combination for, so a jump the session would refuse is not drawn.
final class ReachableLayoutsTests: XCTestCase {
    private func combination(_ schema: String, _ layout: KeyboardLayoutKind) -> KeyboardResourceSet.Combination {
        .init(schemaID: schema, engineSchemaID: schema, layout: layout, name: schema)
    }

    func testReachableAreTheRunningLayoutAndThoseTheSchemaCanRun() {
        let combinations = [
            combination("pinyin", .qwerty26), combination("pinyin", .phone9),
            combination("wubi", .qwerty26), combination("wubi", .merged14),
        ]
        XCTAssertEqual(
            KeyboardResourceSet.reachableLayouts(in: combinations, schemaID: "pinyin", running: .qwerty26),
            [.qwerty26, .phone9])
        XCTAssertEqual(
            KeyboardResourceSet.reachableLayouts(in: combinations, schemaID: "wubi", running: .qwerty26),
            [.qwerty26, .merged14])
        // The running layout stays reachable even when no combination lists it.
        XCTAssertEqual(
            KeyboardResourceSet.reachableLayouts(in: combinations, schemaID: "unknown", running: .merged18),
            [.merged18])
    }
}
