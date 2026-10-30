import Foundation

// Preferences are separate from pickup-data.json: no record migration required.
enum WidgetSlot: String, CaseIterable, Identifiable {
    case a, b
    var id: String { rawValue }
    var title: String { self == .a ? "组件 A" : "组件 B" }
    var kind: String { "ParcelKeeperSlot" + rawValue.uppercased() }
}

struct WidgetSlotBinding {
    private let directory: URL
    init(containerURL: URL? = nil) throws {
        let group = Bundle.main.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String
        guard let container = containerURL ?? group.flatMap({ FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }) else {
            throw PickupStorageError.appGroupUnavailable
        }
        directory = container.appendingPathComponent("ParcelKeeper", isDirectory: true)
    }
    private func url(_ slot: WidgetSlot) -> URL {
        directory.appendingPathComponent("widget-slot-\(slot.rawValue).json")
    }
    func groupID(for slot: WidgetSlot) throws -> UUID? {
        let file = url(slot)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(UUID?.self, from: Data(contentsOf: file))
    }
    func save(_ groupID: UUID?, for slot: WidgetSlot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(groupID).write(to: url(slot), options: .atomic)
        guard try self.groupID(for: slot) == groupID else {
            throw PickupStorageError.invalidData("组件分组设置回读失败")
        }
    }
}
