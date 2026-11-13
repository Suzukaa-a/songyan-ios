import XCTest

@testable import PackageManager

final class ConfigurationBackupRetentionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testKeepsTheNewestTenBackupsAndThreePreRestoreOnes() {
        let regular = (0..<14).map { URL(fileURLWithPath: "/b/松烟-\($0).songyanbackup") }
        let safety = (0..<5).map { URL(fileURLWithPath: "/b/恢复前-\($0)\(ConfigurationBackupRetention.safetySuffix)") }
        let other = URL(fileURLWithPath: "/b/notes.txt")
        let dates = Dictionary(
            uniqueKeysWithValues: (regular + safety).enumerated().map { ($1, base.addingTimeInterval(Double($0))) }
                + [(other, base)])

        let surplus = Set(ConfigurationBackupRetention.surplus(regular + safety + [other]) { dates[$0]! })

        XCTAssertEqual(surplus, Set(regular.prefix(4) + safety.prefix(2)))
    }
}
