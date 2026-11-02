import Foundation

/// Only fixed schema labels, fixed return codes and HTTP integers; never raw values.
struct TaobaoTrialDiagnostic: LocalizedError {
    let stage: String
    let reason: TaobaoTrialError
    let status: Int?
    let codes: String
    let shape: String
    init(stage: String, reason: TaobaoTrialError, status: Int?, root: [String: Any]?) {
        self.stage = stage; self.reason = reason; self.status = status
        let allowed: Set<String> = ["SUCCESS", "FAIL_SYS_SESSION_EXPIRED", "FAIL_SYS_TOKEN_EXOIRED", "FAIL_SYS_TOKEN_EXPIRED", "FAIL_SYS_TOKEN_EMPTY", "FAIL_SYS_USER_VALIDATE", "FAIL_SYS_ILLEGAL_ACCESS", "FAIL_SYS_API_NOT_FOUNDED", "FAIL_SYS_API_STOP_SERVICE", "FAIL_SYS_PARAM_MISSING", "FAIL_SYS_PARAM_FORMAT_ERROR", "FAIL_SYS_TRAFFIC_LIMIT", "FAIL_SYS_SERVICE_FAULT", "FAIL_SYS_LOGIN_REQUIRED"]
        let raw = root?["ret"] as? [String] ?? []
        codes = raw.isEmpty ? "缺少ret" : raw.prefix(4).map {
            let code = String($0.components(separatedBy: "::")[0])
            return allowed.contains(code) ? code : "未识别返回码"
        }.joined(separator: ",")
        if let root {
            let data = root["data"] as? [String: Any]
            let nested = data?["data"] as? [String: Any]
            shape = "data=\(data == nil ? "否" : "是")；data.mainOrders=\(data?["mainOrders"] is [[String: Any]] ? "是" : "否")；data.data.mainOrders=\(nested?["mainOrders"] is [[String: Any]] ? "是" : "否")；data.result字符串=\(data?["result"] is String ? "是" : "否")"
        } else { shape = "非JSON或未收到JSON对象" }
    }
    var errorDescription: String? {
        "\(reason.localizedDescription)\n阶段：\(stage)；HTTP \(status.map(String.init) ?? "未收到")；\(codes)\n\(shape)"
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
