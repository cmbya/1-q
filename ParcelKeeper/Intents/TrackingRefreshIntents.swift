import AppIntents
import Foundation

struct RefreshPendingShipmentsIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新未签收快递物流"
    static var description = IntentDescription("使用已配置的UAPI逐票刷新运输中、派送中、待取件及异常快递；可能消耗积分，不主动请求写入确认。")
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let report = try await TrackingRefreshService.live().refreshPending()
        return .result(value: report.message, dialog: "\(report.message)")
    }
}

struct RefreshShipmentIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新指定快递物流"
    static var description = IntentDescription("按单号刷新App中已有记录，不新增记录。密钥在App设置中配置。")
    @Parameter(title: "快递单号") var trackingNumber: String
    @Parameter(title: "收件人手机尾号（可选）") var phone: String?
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let completed = try await TrackingRefreshService.live().refresh(trackingNumber: trackingNumber, phone: phone)
        let message = completed ? "物流已更新，本次新增签收。" : "物流已更新。"
        return .result(value: message, dialog: "\(message)")
    }
}
