import XCTest
@testable import ParcelKeeper

final class AppGroupResolverTests: XCTestCase {
    private func item(_ id: String, data: Bool = false, selected: Bool = false) -> AppGroupResolver.Candidate {
        .init(id: id, url: URL(fileURLWithPath: "/unused"), hasData: data, selected: selected)
    }
    func testNoArbitrarySelectionOrSilentDataSwitch() throws {
        XCTAssertThrowsError(try AppGroupResolver.selectedID([]))
        XCTAssertThrowsError(try AppGroupResolver.selectedID([item("group.a"), item("group.b")]))
        XCTAssertThrowsError(try AppGroupResolver.selectedID([item("group.a")]))
        XCTAssertEqual(try AppGroupResolver.selectedID([item("group.a"), item("group.b", data: true)]), "group.b")
        XCTAssertEqual(try AppGroupResolver.selectedID([item("group.a", selected: true), item("group.b")]), "group.a")
        XCTAssertThrowsError(try AppGroupResolver.selectedID([item("group.a", selected: true), item("group.b", data: true)]))
        XCTAssertThrowsError(try AppGroupResolver.selectedID([item("group.a", data: true), item("group.b", data: true)]))
        XCTAssertThrowsError(try AppGroupResolver.selectedID([item("group.a", selected: true), item("group.b", selected: true)]))
    }
    func testProfileExtractionIsOnlyCandidateDiscovery() throws {
        let plist: [String: Any] = ["Entitlements": ["com.apple.security.application-groups": ["group.example.a", "group.*", "invalid"]]]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var cms = Data([0x30, 0x82, 0xff])
        cms.append(xml)
        cms.append(Data([0x00, 0xff]))
        XCTAssertEqual(AppGroupResolver.profileGroups(cms), ["group.example.a"])
        XCTAssertTrue(AppGroupResolver.profileGroups(Data("bad profile".utf8)).isEmpty)
    }
    func testTenSlotsPreserveABNamesAndUseDistinctKinds() {
        XCTAssertEqual(WidgetSlot.allCases.count, 10)
        XCTAssertEqual(Set(WidgetSlot.allCases.map(\.kind)).count, 10)
        XCTAssertEqual(WidgetSlot.a.rawValue, "a")
        XCTAssertEqual(WidgetSlot.b.kind, "ParcelKeeperSlotB")
        XCTAssertEqual(WidgetSlot.j.title, "组件 J")
    }
}
