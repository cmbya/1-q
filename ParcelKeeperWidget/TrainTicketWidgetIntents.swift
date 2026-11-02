import AppIntents
import Foundation
import WidgetKit

struct BrowseTrainTicketWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "切换组件火车票"
    static var description = IntentDescription("仅切换此组件的有效车票浏览偏好，不修改车票。固定模式切票后进入手动浏览。")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "组件槽位") var slot: String
    @Parameter(title: "方向") var direction: Int
    @Parameter(title: "当前车票快照") var expectedTicketID: String?

    init() {}
    init(slot: TrainWidgetSlot, direction: Int, expectedTicketID: UUID?) {
        self.slot = slot.rawValue
        self.direction = direction
        self.expectedTicketID = expectedTicketID?.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let target = TrainWidgetSlot(rawValue: slot), direction == -1 || direction == 1 else {
            throw PickupStorageError.invalidData("组件槽位或切换方向无效。")
        }
        let expected: UUID?
        if let raw = expectedTicketID {
            guard raw.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil,
                  let parsed = UUID(uuidString: raw) else {
                throw PickupStorageError.invalidData("当前车票标识无效，请刷新组件后重试。")
            }
            expected = parsed
        } else {
            expected = nil
        }
        let group = try AppGroupResolver.groupID()
        let store = try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData)
        try store.browseTrainWidget(slot: target, direction: direction, expectedTicketID: expected)
        WidgetCenter.shared.reloadTimelines(ofKind: target.kind)
        return .result()
    }
}

struct ResetTrainTicketWidgetBrowsingIntent: AppIntent {
    static var title: LocalizedStringResource = "组件回到自动车票"
    static var description = IntentDescription("清除此组件的手动浏览或固定选择，自动显示首张有效车票，不修改车票。")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "组件槽位") var slot: String

    init() {}
    init(slot: TrainWidgetSlot) { self.slot = slot.rawValue }
    @Parameter(title: "当前绑定快照") var expectedBinding: String?
    init(slot: TrainWidgetSlot, expectedBinding: TrainWidgetBinding) {
        self.slot = slot.rawValue
        self.expectedBinding = try? String(data: JSONEncoder().encode(expectedBinding), encoding: .utf8)
    }

    func perform() async throws -> some IntentResult {
        guard let target = TrainWidgetSlot(rawValue: slot) else {
            throw PickupStorageError.invalidData("组件槽位无效。")
        }
        guard let raw = expectedBinding, let bytes = raw.data(using: .utf8),
              let expected = try? JSONDecoder().decode(TrainWidgetBinding.self, from: bytes), expected.slot == target else {
            throw PickupStorageError.staleCompletion
        }
        let group = try AppGroupResolver.groupID()
        let store = try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData)
        try store.resetTrainWidgetBrowsing(slot: target, expectedBinding: expected)
        WidgetCenter.shared.reloadTimelines(ofKind: target.kind)
        return .result()
    }
}
