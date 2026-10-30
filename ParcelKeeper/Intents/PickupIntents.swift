import AppIntents
import Foundation
import WidgetKit

enum PickupIntentError: LocalizedError {
    case emptyCode, emptyText, invalidGroup, duplicate, confirmationRequired, noCandidate, aiFailed

    var errorDescription: String? {
        switch self {
        case .emptyCode: return "取件码不能为空。"
        case .emptyText: return "输入文本不能为空。"
        case .invalidGroup: return "分组已删除或无效，请重新选择分组。"
        case .duplicate: return "此分组已有未完成的相同取件码，未重复添加。已完成的历史取件码可以再次使用。"
        case .confirmationRequired: return "识别结果不明确，请在 App 中编辑；尚未保存。"
        case .noCandidate: return "未识别到取件码；请在 App 中编辑，尚未保存。"
        case .aiFailed: return "AI 识别失败，请检查 AI 配置或在 App 中手动处理；尚未保存。"
        }
    }
}

/// All validation that depends on mutable data occurs inside the store transaction.
struct PickupIntentService {
    let store: SharedPickupStore
    var reloadWidget: () -> Void = {
        WidgetCenter.shared.reloadTimelines(ofKind: "ParcelKeeperPickupWidget")
        for slot in WidgetSlot.allCases { WidgetCenter.shared.reloadTimelines(ofKind: slot.kind) }
    }
    var aiEnabled: () -> Bool = { false }
    var aiExtract: (String) async throws -> AIExtraction = { _ in throw AIServiceError.disabled }

    static func live() throws -> PickupIntentService {
        let group = Bundle.main.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String
        let ai = AIService()
        return PickupIntentService(store: try SharedPickupStore(appGroupID: group, accessMode: .existingSharedData),
                                   aiEnabled: { ai.loadConfiguration().enabled },
                                   aiExtract: { try await ai.extract($0) })
    }

    func groups() throws -> [PickupGroup] {
        try store.snapshot().groups.sorted {
            $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder
        }
    }

    func add(code: String, location: String?, groupID: UUID, source: String?, expectedGroupName: String? = nil) throws {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw PickupIntentError.emptyCode }
        try store.transaction { data in
            guard let group = data.groups.first(where: { $0.id == groupID }),
                  expectedGroupName == nil || group.name == expectedGroupName else { throw PickupIntentError.invalidGroup }
            // A match is only a possible duplicate, never proof of the same order.
            guard !data.records.contains(where: { $0.groupID == groupID && !$0.isCompleted && $0.code.trimmingCharacters(in: .whitespacesAndNewlines) == normalized }) else {
                throw PickupIntentError.duplicate
            }
            data.records.append(PickupRecord(groupID: groupID, code: normalized,
                                             location: location ?? "", source: source ?? ""))
        }
        reloadWidget()
    }

    func recognize(text: String, groupID: UUID,
                   confirm: (PickupTextParser.Candidate, String) async throws -> Void) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PickupIntentError.emptyText }
        guard let group = try groups().first(where: { $0.id == groupID }) else { throw PickupIntentError.invalidGroup }
        let result = PickupTextParser().parse(text)
        guard !result.isAmbiguous else { throw PickupIntentError.confirmationRequired }
        let candidate: PickupTextParser.Candidate
        if result.candidates.count == 1, !result.isAmbiguous, let local = result.candidates.first,
           !(aiEnabled() && (local.location ?? "").isEmpty) {
            candidate = local
        } else {
            guard aiEnabled() else {
                if !result.candidates.isEmpty || result.isAmbiguous { throw PickupIntentError.confirmationRequired }
                throw PickupIntentError.noCandidate
            }
            let local = result.candidates.count == 1 ? result.candidates.first : nil
            do {
                try Task.checkCancellation()
                let extracted = try await aiExtract(text)
                try Task.checkCancellation()
                guard !extracted.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PickupIntentError.aiFailed }
                // Enrichment must not silently replace an already grounded code.
                if let local, extracted.code != local.code { throw PickupIntentError.aiFailed }
                candidate = PickupTextParser.Candidate(code: extracted.code,
                    location: extracted.location.isEmpty ? local?.location : extracted.location, source: nil)
            } catch is CancellationError { throw CancellationError() }
            catch AIServiceError.cancelled { throw AIServiceError.cancelled }
            catch {
                guard let local else { throw PickupIntentError.aiFailed }
                // Only optional enrichment failed. Confirmation still shows the
                // local code and an unknown location rather than losing the code.
                candidate = local
            }
        }
        try await confirm(candidate, group.name)
        try Task.checkCancellation()
        // Never persist the input text or inferred source; validate the displayed group again atomically.
        try add(code: candidate.code, location: candidate.location, groupID: groupID,
                source: nil, expectedGroupName: group.name)
    }
}

struct PickupGroupEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "取件分组")
    static var defaultQuery = PickupGroupQuery()

    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ group: PickupGroup) { id = group.id; name = group.name }
}

struct PickupGroupQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PickupGroupEntity] {
        let groups = try PickupIntentService.live().groups()
        return identifiers.compactMap { id in groups.first(where: { $0.id == id }).map(PickupGroupEntity.init) }
    }

    func suggestedEntities() async throws -> [PickupGroupEntity] {
        try PickupIntentService.live().groups().map(PickupGroupEntity.init)
    }
}

struct AddPickupIntent: AppIntent {
    static var title: LocalizedStringResource = "添加取件码"
    static var description = IntentDescription("将已提取的取件码保存到选定分组。")

    @Parameter(title: "取件码") var code: String
    @Parameter(title: "地点") var location: String?
    @Parameter(title: "分组") var group: PickupGroupEntity
    @Parameter(title: "来源或备注") var source: String?
    @Parameter(title: "写入前确认", default: true) var confirmBeforeSaving: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if confirmBeforeSaving {
            let dialog: IntentDialog = "请确认保存取件码：\(code)，地点：\(location ?? "未提供")，分组：\(group.name)。"
            if #available(iOS 18.0, *) { try await requestConfirmation(dialog: dialog) }
            else { try await requestConfirmation(result: .result(dialog: dialog), showPrompt: true) }
        }
        try Task.checkCancellation()
        try PickupIntentService.live().add(code: code, location: location, groupID: group.id, source: source)
        return .result(dialog: "取件码已保存。")
    }
}

struct RecognizePickupIntent: AppIntent {
    static var title: LocalizedStringResource = "识别并添加取件码"
    static var description = IntentDescription("识别文本，在确认唯一结果后保存。")

    @Parameter(title: "原始文本") var text: String
    @Parameter(title: "分组") var group: PickupGroupEntity
    @Parameter(title: "写入前确认", default: true) var confirmBeforeSaving: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await PickupIntentService.live().recognize(text: text, groupID: group.id) { candidate, groupName in
            guard confirmBeforeSaving else { return }
            let location = candidate.location ?? "未识别"
            let dialog: IntentDialog = "请确认保存取件码：\(candidate.code)，地点：\(location)，分组：\(groupName)。"
            if #available(iOS 18.0, *) {
                try await requestConfirmation(dialog: dialog)
            } else {
                try await requestConfirmation(result: .result(dialog: dialog), showPrompt: true)
            }
        }
        return .result(dialog: "取件码已保存。")
    }
}
