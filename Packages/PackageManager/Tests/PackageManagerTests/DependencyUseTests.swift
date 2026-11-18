import XCTest

@testable import PackageManager

final class DependencyUseTests: XCTestCase {
    private func folder(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("use-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        for (name, text) in files { try Data(text.utf8).write(to: url.appendingPathComponent(name)) }
        return url
    }

    func testAPackageReadsAnotherWhenItCarriesACopyOfOneOfItsDataFiles() throws {
        let essay = try folder(["essay.txt": "我\t1\n", "README.md": "a"])
        let user = try folder(["essay.txt": "我\t1\n", "main.schema.yaml": "x"])
        XCTAssertTrue(DependencyUse.reads(user: user, other: essay))
    }

    func testNeitherAnotherSizeNorAnotherFileNorItselfCounts() throws {
        let essay = try folder(["essay.txt": "我\t1\n"])
        XCTAssertFalse(DependencyUse.reads(user: try folder(["essay.txt": "longer text here"]), other: essay))
        XCTAssertFalse(DependencyUse.reads(user: try folder(["main.dict.yaml": "x"]), other: essay))
        XCTAssertFalse(DependencyUse.reads(user: essay, other: essay))
        let docs = try folder(["README.md": "a"])
        XCTAssertFalse(DependencyUse.reads(user: try folder(["README.md": "a"]), other: docs))
    }
}
