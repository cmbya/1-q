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
    func testDamagedSlotDoesNotBlockOthersAndRequiresExplicitRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = try WidgetSlotBinding(containerURL: root)
        let b = UUID(), j = UUID(), replacement = UUID()
        try binding.save(b, for: .b)
        try binding.save(j, for: .j)
        let file = root.appendingPathComponent("ParcelKeeper/widget-slot-a.json")
        let corrupt = Data("bad-json".utf8)
        try corrupt.write(to: file)
        let loaded = binding.loadAll()
        XCTAssertEqual(loaded.count, WidgetSlot.allCases.count)
        guard let damaged = loaded[.a] else { return XCTFail("Missing slot A result") }
        XCTAssertThrowsError(try damaged.get())
        XCTAssertEqual(try XCTUnwrap(loaded[.b]).get(), b)
        XCTAssertEqual(try XCTUnwrap(loaded[.j]).get(), j)
        XCTAssertNil(try XCTUnwrap(loaded[.c]).get())
        XCTAssertEqual(try Data(contentsOf: file), corrupt, "Loading must preserve damaged bytes")
        try binding.save(UUID(), for: .c)
        XCTAssertEqual(try Data(contentsOf: file), corrupt, "Editing another slot must not clear A")
        try binding.save(replacement, for: .a)
        let reopened = try WidgetSlotBinding(containerURL: root)
        XCTAssertEqual(try reopened.groupID(for: .a), replacement)
        XCTAssertEqual(try reopened.groupID(for: .b), b)
        XCTAssertEqual(try reopened.groupID(for: .j), j)
        try corrupt.write(to: file)
        try reopened.save(nil, for: .a)
        XCTAssertNil(try binding.groupID(for: .a), "Explicit unbind also repairs damaged JSON")
        XCTAssertEqual(try binding.groupID(for: .b), b)
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
