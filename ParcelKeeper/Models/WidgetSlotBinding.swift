import Foundation

// Preferences are separate from pickup-data.json: no record migration required.
enum WidgetSlot: String, CaseIterable, Identifiable {
    case a, b, c, d, e, f, g, h, i, j
    var id: String { rawValue }
    var title: String { "组件 " + rawValue.uppercased() }
    var kind: String { "ParcelKeeperSlot" + rawValue.uppercased() }
}

struct WidgetSlotBinding {
    private let directory: URL
    init(containerURL: URL? = nil) throws {
        let container: URL
        if let injected = containerURL { container = injected }
        else { container = try AppGroupResolver.container() }
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
