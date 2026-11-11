import Foundation

/// Latest timestamped event only. Deposit/agent signatures never imply recipient collection.
enum MallDeliveryState {
    /// Independent newest events must not share conditional/forecast scope.
    /// The caller selects the newest timestamp group; never concatenate its descriptions.
    static func recipientCollected(events: [String]) -> Bool {
        events.contains { recipientCollected(latest: $0) }
    }
    /// Narrow recipient collection evidence; generic signed/妥投 is not sufficient.
    static func recipientCollected(latest: String) -> Bool {
        let text = latest.precomposedStringWithCompatibilityMapping.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !isConditional(text), !collectionDenied(text) else { return false }
        return factualClauses(text).contains { clause in
            guard !["请", "請", "待", "等待", "需", "须", "务必", "以便", "才能", "方可"].contains(where: clause.contains) else { return false }
            return clause.range(of: #"(?:签收人|收件人|取件人|本人|客户|用户)(?:已|已经)?凭(?:取货|取件)码(?:完成取件|签收)"#, options: .regularExpression) != nil ||
                clause.range(of: #"(?:本人|收件人)(?:本人)?(?:已|已经)?(?:确认)?签收|已由(?:收件人)?本人签收|签收人(?:为|是)(?:收件人|本人)"#, options: .regularExpression) != nil ||
                ["已完成取件", "已在代收点取出", "已从代收点取出", "已从快递柜取出", "已从丰巢取出", "收件人已取件", "本人已取件", "客户已取件", "用户已取走", "收件人领取成功"].contains(where: clause.contains)
        }
    }
    /// A later correction in the same node must veto an earlier positive phrase.
    private static func collectionDenied(_ text: String) -> Bool {
        ["尚未", "未签收", "未实际签收", "未取件", "未领取", "未完成", "没有签收", "没有取件", "未能", "未收到", "未收货", "非本人", "非收件人", "并非", "不是", "误签", "虚假签收", "代签", "代收", "门卫", "保安", "前台", "邻居", "退回", "退货", "退件", "取消", "撤销", "拒收", "失败", "异常", "重新入库", "重新派送", "待取件", "待领取", "等待领取", "核实", "核验", "疑似", "无法确认", "?", "？"].contains {
            // A confirmed exit may name the pickup point as its location.
            text.replacingOccurrences(of: "代收点", with: "取件点").contains($0)
        } || text.range(of: #"(?:未(?:曾|能|有)?|没(?:有|能)?)(?:签收|取件|领取|取出|收货|收到)|(?:须|应当|要求|指定|仅限|支持|安排|选择)(?:由)?(?:签收人|本人|收件人|用户|客户).{0,8}(?:签收|取件)"#, options: .regularExpression) != nil
    }
    private static func isConditional(_ latest: String) -> Bool {
        ["预计", "预估", "如果", "如已", "若已", "如您", "若您", "如有", "若有", "签收后", "取件后", "是否", "计划", "预约", "可能", "签收服务", "签收要求", "签收方式", "签收流程"].contains(where: latest.contains) ||
            latest.range(of: #"(?:签收|取件)(?:完成|成功)?(?:前|时|中)|(?:本人|收件人|用户|客户|您)(?:将|会|正|拟|可).{0,8}(?:签收|领取|取件)"#, options: .regularExpression) != nil
    }
    private static func factualClauses(_ latest: String) -> [String] {
        latest.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n")).filter { clause in
            !["尚未", "未签收", "未实际签收", "未取件", "未妥投", "未完成", "没有签收", "没有取件", "未能", "请确认"].contains(where: clause.contains)
        }
    }
    /// Latest successful, dated response only. Station deposits beat door wording.
    static func homeDelivered(events: [String], status: String, station: String, hasPickupCode: Bool) -> Bool {
        guard !events.isEmpty else { return false }
        let text = events.joined(separator: "；")
        let pickupPoints = ["驿站", "代收点", "自提点", "自提柜", "快递柜", "丰巢", "菜鸟", "门卫", "前台", "保安", "便利店", "快递超市"]
        guard !pickupPoints.contains(where: text.contains),
              !["预计", "即将", "将于", "尚未", "未送", "没有送", "未妥投", "未签收", "失败", "退回", "退货", "拒收", "异常", "是否", "如果", "待取件", "请凭", "请将", "请放", "预约", "疑似", "未能"].contains(where: text.contains) else { return false }
        let atDoor = events.contains { $0.range(of: #"已(?:经)?(?:成功)?(?:送(?:到|至|达)|派送(?:到|至)|放(?:在|到|至)?|投递(?:到|至)).{0,16}(?:门口|门前|家中|家里|住处)"#, options: .regularExpression) != nil }
        if atDoor { return true }
        guard !hasPickupCode, !pickupPoints.contains(where: station.contains) else { return false }
        return status == "signed" || text.contains("已妥投") || text.contains("已签收")
    }
    static func resolve(latest: String) -> ShipmentStatus? {
        // Forecast/conditional scope may span commas; don't detach a positive clause from it.
        guard !isConditional(latest) else { return nil }
        let facts = factualClauses(latest)
        if recipientCollected(latest: latest) { return .delivered }
        let station = ["待取件", "等待取件", "待您领取", "请及时取件", "请尽快完成取件", "菜鸟驿站代收", "请凭码取件", "请凭取件码", "丰巢暂存", "快递柜暂存", "已放入快递柜", "已存入快递柜", "已送达菜鸟驿站", "已送达驿站", "已送达代收点", "驿站已签收", "代收点已签收", "已签收至菜鸟驿站"].contains(where: latest.contains)
        if station { return .readyForPickup }
        if facts.contains(where: { clause in ["已签收", "已妥投"].contains(where: clause.contains) }) { return .delivered }
        if facts.contains(where: { clause in ["正在派送", "正在配送", "派件中", "派送中", "配送中"].contains(where: clause.contains) }) { return .outForDelivery }
        if facts.contains(where: { clause in ["运输中", "已到达转运中心", "已到达中转", "已离开转运中心", "已揽收", "已揽件", "快递员已取件"].contains(where: clause.contains) }) { return .inTransit }
        return nil
    }
}
