// Legacy direct marketplace import is opt-in; source is retained for restoration.
#if ENABLE_DIRECT_MALL_IMPORT
import Foundation

/// Only fixed schema labels, fixed return codes and HTTP integers; never raw values.
struct TaobaoTrialDiagnostic: LocalizedError {
    let stage: String
    let reason: TaobaoTrialError
    let status: Int?
    let codes: String
    let shape: String
    let transport: String
    let attempt: Int
    let byteCount: Int?
    init(stage: String, reason: TaobaoTrialError, status: Int?, root: [String: Any]?, transport: String = "无", attempt: Int = 1, byteCount: Int? = nil) {
        self.stage = stage; self.reason = reason; self.status = status
        self.transport = transport; self.attempt = attempt; self.byteCount = byteCount
        let allowed: Set<String> = ["SUCCESS", "FAIL_SYS_SESSION_EXPIRED", "FAIL_SYS_TOKEN_EXOIRED", "FAIL_SYS_TOKEN_EXPIRED", "FAIL_SYS_TOKEN_EMPTY", "FAIL_SYS_USER_VALIDATE", "FAIL_SYS_ILLEGAL_ACCESS", "FAIL_SYS_API_NOT_FOUNDED", "FAIL_SYS_API_STOP_SERVICE", "FAIL_SYS_PARAM_MISSING", "FAIL_SYS_PARAM_FORMAT_ERROR", "FAIL_SYS_TRAFFIC_LIMIT", "FAIL_SYS_SERVICE_FAULT", "FAIL_SYS_LOGIN_REQUIRED", "FAIL_BIZ_ORDER_NOT_FOUND"]
        let raw = root?["ret"] as? [String] ?? []
        codes = raw.isEmpty ? "缺少ret" : raw.prefix(4).map {
            let code = String($0.components(separatedBy: "::")[0])
            return allowed.contains(code) ? code : "未识别返回码"
        }.joined(separator: ",")
        if let root {
            let data = root["data"] as? [String: Any]
            let nested = data?["data"] as? [String: Any]
            if stage == "物流详情" {
                let waybillKeys: Set<String> = ["mailNo", "waybillCode", "logisticsNo"]
                var visited = 0
                func hasWaybill(_ node: Any, depth: Int) -> Bool {
                    visited += 1
                    guard depth <= 16, visited <= 10000 else { return false }
                    if let object = node as? [String: Any] {
                        if !waybillKeys.isDisjoint(with: object.keys) { return true }
                        return object.values.contains { hasWaybill($0, depth: depth + 1) }
                    }
                    if let array = node as? [Any] { return array.contains { hasWaybill($0, depth: depth + 1) } }
                    return false
                }
                shape = "data=\(data == nil ? "否" : "是")；运单字段=\(data.map { hasWaybill($0, depth: 0) } == true ? "是" : "否")"
            } else {
                shape = "data=\(data == nil ? "否" : "是")；data.mainOrders=\(data?["mainOrders"] is [[String: Any]] ? "是" : "否")；data.data.mainOrders=\(nested?["mainOrders"] is [[String: Any]] ? "是" : "否")；data.result字符串=\(data?["result"] is String ? "是" : "否")"
            }
        } else { shape = "非JSON或未收到JSON对象" }
    }
    var errorDescription: String? {
        let api = stage == "物流详情" ? "mtop.taobao.logistics.detailorlist.query" : "mtop.taobao.order.queryboughtlistv2"
        return "\(reason.localizedDescription)\n阶段：\(stage)；HTTP \(status.map(String.init) ?? "未收到")；\(codes)\n\(shape)\n接口：\(api) / 1.0（GET）\n尝试：\(attempt)/2（仅令牌刷新允许重试）\n响应字节：\(byteCount.map(String.init) ?? "未收到")\n网络错误：\(transport)\n隐私：未包含Cookie、令牌、签名、订单内容、原始响应或完整请求链接。"
    }
}

extension TaobaoTrialPolicy {
    static func blockedDestination(_ url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            let scheme = url.scheme?.lowercased() ?? "未知"
            return ["taobao", "tbopen", "alipays", "alipay"].contains(scheme) ? "\(scheme)://（外部App）" : "其他协议（已隐藏地址）"
        }
        // Only show conventional DNS hostnames, not arbitrary URL/userinfo data.
        guard let host = url.host?.lowercased(), host.count <= 253,
              host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil else { return "网页地址（已隐藏）" }
        return "\(scheme)://\(host)"
    }
}
#endif
