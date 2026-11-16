import XCTest

@testable import KeyboardCore

final class AppGroupResolutionTests: XCTestCase {
    private let declared = "group.app.songyan.shared"

    func testTheDeclaredGroupWinsWhenGranted() {
        let group = AppGroupResolution.resolve(
            declared: declared, recorded: ["group.app.songyan.shared.ABCDE12345"], profileGroups: [],
            isGranted: { _ in true })
        XCTAssertEqual(group, declared)
    }

    /// Regression: AltStore and SideStore rename the group to `<group>.<TEAMID>` when they re-sign,
    /// so the build-time name has no container.
    func testARenamedGroupIsFoundInAltStoresRecordOrTheProfile() {
        let renamed = "group.app.songyan.shared.ABCDE12345"
        for (recorded, profile) in [([renamed], [String]()), ([], [renamed])] {
            let group = AppGroupResolution.resolve(
                declared: declared, recorded: recorded, profileGroups: profile, isGranted: { $0 == renamed })
            XCTAssertEqual(group, renamed)
        }
    }

    func testOtherGroupsAreNeverTaken() {
        let group = AppGroupResolution.resolve(
            declared: declared, recorded: ["group.other.app"], profileGroups: ["group.app.songyan.sharedX"],
            isGranted: { _ in false })
        XCTAssertEqual(group, declared)
    }

    func testProfileGroupsAreReadFromTheEnvelope() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Entitlements</key><dict>
            <key>com.apple.security.application-groups</key>
            <array><string>group.app.songyan.shared.ABCDE12345</string></array>
            </dict></dict></plist>
            """
        var data = Data([0x30, 0x82, 0x01, 0x02, 0xFF])
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0xA0, 0x82]))
        XCTAssertEqual(AppGroupResolution.profileGroups(data), ["group.app.songyan.shared.ABCDE12345"])
        XCTAssertEqual(AppGroupResolution.profileGroups(Data([1, 2, 3])), [])
    }
}
