import XCTest
@testable import ParcelKeeper

final class PickupIntentTests: XCTestCase {
    private var directory: URL!
    private var store: SharedPickupStore!
    private var service: PickupIntentService!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SharedPickupStore(appGroupID: nil, legacyURL: directory.appendingPathComponent("no-legacy.json"), containerURL: directory)
        service = PickupIntentService(store: store)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testStableGroupIDAndRename() throws {
        let original = try XCTUnwrap(service.groups().first)
        try store.transaction { data in
            let index = try XCTUnwrap(data.groups.firstIndex { $0.id == original.id })
            data.groups[index].name = "新名称"
        }
        let renamed = try XCTUnwrap(service.groups().first { $0.id == original.id })
        XCTAssertEqual(renamed.name, "新名称")
        XCTAssertEqual(PickupGroupEntity(renamed).id, original.id)
    }

    func testAddAndPossibleDuplicateAcrossGroups() throws {
        let groups = try service.groups()
        try service.add(code: " 001-A ", location: "柜台", groupID: groups[0].id, source: "测试")
        XCTAssertThrowsError(try service.add(code: "001-A", location: nil, groupID: groups[0].id, source: nil)) {
            guard case PickupIntentError.duplicate = $0 else { return XCTFail("unexpected error: \($0)") }
        }
        try service.add(code: "001-A", location: nil, groupID: groups[1].id, source: nil)
        let records = try store.snapshot().records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].code, "001-A")
        XCTAssertEqual(records[0].location, "柜台")
        XCTAssertEqual(records[0].source, "测试")
        XCTAssertEqual(Set(records.map(\.groupID)), Set(groups.map(\.id)))
    }

    func testInvalidInputAndDeletedGroupDoNotWrite() throws {
        let group = try XCTUnwrap(service.groups().last)
        XCTAssertThrowsError(try service.add(code: " \n", location: nil, groupID: group.id, source: nil))
        try store.transaction { $0.groups.removeAll { $0.id == group.id } }
        XCTAssertThrowsError(try service.add(code: "123", location: nil, groupID: group.id, source: nil)) {
            guard case PickupIntentError.invalidGroup = $0 else { return XCTFail("unexpected error: \($0)") }
        }
        XCTAssertTrue(try store.snapshot().records.isEmpty)
    }

    func testRecognitionConfirmationAndFailurePaths() async throws {
        let id = try XCTUnwrap(service.groups().first?.id)
        struct Cancelled: Error {}
        do {
            try await service.recognize(text: "取件码00123", groupID: id) { _, _ in throw Cancelled() }
            XCTFail("confirmation should fail")
        } catch is Cancelled {}
        XCTAssertTrue(try store.snapshot().records.isEmpty)
        for text in ["没有可识别内容", "取件码00123, 00456"] {
            do {
                try await service.recognize(text: text, groupID: id) { _, _ in XCTFail("must not confirm") }
                XCTFail("ambiguous or missing result should fail")
            } catch is PickupIntentError {}
        }
        try await service.recognize(text: "取件码00123，到菜鸟驿站取件", groupID: id) { candidate, name in
            XCTAssertEqual(candidate.code, "00123")
            XCTAssertEqual(candidate.location, "菜鸟驿站")
            XCTAssertEqual(name, try self.service.groups().first?.name)
        }
        let records = try store.snapshot().records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].code, "00123")
        XCTAssertEqual(records[0].location, "菜鸟驿站")
        XCTAssertEqual(records[0].source, "")
    }

    func testAIFallbackAndLocalPriority() async throws {
        let id = try XCTUnwrap(service.groups().first?.id)
        var calls = 0
        service.aiEnabled = { true }
        service.aiExtract = { text in
            calls += 1
            XCTAssertEqual(text, "请凭 7788 到东门领取")
            return AIExtraction(code: "7788", location: "东门", source: "私密来源", model: "mock", failures: [])
        }
        try await service.recognize(text: "取件码00123", groupID: id) { _, _ in }
        XCTAssertEqual(calls, 0)
        try await service.recognize(text: "请凭 7788 到东门领取", groupID: id) { candidate, _ in
            XCTAssertEqual(candidate.code, "7788")
            XCTAssertEqual(candidate.location, "东门")
            XCTAssertNil(candidate.source)
            XCTAssertEqual(try self.store.snapshot().records.count, 1)
        }
        XCTAssertEqual(calls, 1)
        let records = try store.snapshot().records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].source, "")
    }

    func testAIFailureAmbiguityAndCancelledConfirmationNeverSave() async throws {
        let id = try XCTUnwrap(service.groups().first?.id)
        var calls = 0
        service.aiEnabled = { true }
        service.aiExtract = { _ in
            calls += 1
            return AIExtraction(code: "00123", location: "", source: "", model: "mock", failures: [])
        }
        do {
            try await service.recognize(text: "取件码00123, 00456", groupID: id) { _, _ in XCTFail("ambiguous") }
            XCTFail("must require app handling")
        } catch PickupIntentError.confirmationRequired {}
        XCTAssertEqual(calls, 0)
        do {
            try await service.recognize(text: "凭00123领取", groupID: id) { _, _ in throw CancellationError() }
            XCTFail("confirmation cancelled")
        } catch is CancellationError {}
        service.aiExtract = { _ in throw AIServiceError.unavailable }
        do {
            try await service.recognize(text: "凭00123领取", groupID: id) { _, _ in XCTFail("AI failed") }
            XCTFail("AI failure")
        } catch PickupIntentError.aiFailed {}
        XCTAssertTrue(try store.snapshot().records.isEmpty)
    }

    func testRecognitionRevalidatesAfterConfirmation() async throws {
        let group = try XCTUnwrap(service.groups().last)
        do {
            try await service.recognize(text: "取件码123", groupID: group.id) { _, _ in
                try self.store.transaction { $0.groups.removeAll { $0.id == group.id } }
            }
            XCTFail("deleted group should fail")
        } catch PickupIntentError.invalidGroup {}
        XCTAssertTrue(try store.snapshot().records.isEmpty)
        let other = try XCTUnwrap(service.groups().first)
        do {
            try await service.recognize(text: "取件码123", groupID: other.id) { _, _ in
                try self.service.add(code: "123", location: nil, groupID: other.id, source: nil)
            }
            XCTFail("duplicate should fail")
        } catch PickupIntentError.duplicate {}
        XCTAssertEqual(try store.snapshot().records.count, 1)
    }

    func testUnavailableAndReadOnlyStorageFail() throws {
        XCTAssertThrowsError(try SharedPickupStore(appGroupID: nil))
        let readOnly = try SharedPickupStore(appGroupID: nil, legacyURL: directory.appendingPathComponent("no-legacy.json"), containerURL: directory, readOnly: true)
        let id = try XCTUnwrap(service.groups().first?.id)
        XCTAssertThrowsError(try PickupIntentService(store: readOnly).add(code: "123", location: nil, groupID: id, source: nil))
        XCTAssertTrue(try store.snapshot().records.isEmpty)
    }
}
