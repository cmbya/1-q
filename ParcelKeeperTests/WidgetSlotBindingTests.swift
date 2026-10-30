import XCTest
@testable import ParcelKeeper

final class WidgetSlotBindingTests: XCTestCase {
    func testBindingsAreIndependentPersistentAndCanBeCleared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = try WidgetSlotBinding(containerURL: root)
        XCTAssertNil(try binding.groupID(for: .a))
        let a = UUID(), b = UUID()
        try binding.save(a, for: .a)
        try binding.save(b, for: .b)
        let reopened = try WidgetSlotBinding(containerURL: root)
        XCTAssertEqual(try reopened.groupID(for: .a), a)
        XCTAssertEqual(try reopened.groupID(for: .b), b)
        try reopened.save(nil, for: .a)
        XCTAssertNil(try reopened.groupID(for: .a))
        XCTAssertEqual(try reopened.groupID(for: .b), b)
        XCTAssertNotEqual(WidgetSlot.a.kind, WidgetSlot.b.kind)
    }
    func testMalformedBindingIsReportedNotSilentlyReassigned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = try WidgetSlotBinding(containerURL: root)
        try binding.save(UUID(), for: .a)
        let file = root.appendingPathComponent("ParcelKeeper/widget-slot-a.json")
        try Data("bad-json".utf8).write(to: file)
        XCTAssertThrowsError(try binding.groupID(for: .a))
        XCTAssertNil(try binding.groupID(for: .b))
    }
}
