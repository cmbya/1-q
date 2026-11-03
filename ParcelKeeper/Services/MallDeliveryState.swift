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
        guard !isConditional(latest) else { return false }
        return factualClauses(latest).contains { clause in
            guard !["请", "請", "待", "等待", "需", "须", "务必", "以便", "才能", "方可"].contains(where: clause.contains) else { return false }
            return clause.range(of: #"(?:收件人|取件人|本人|客户)凭取件码完成取件"#, options: .regularExpression) != nil ||
                ["已完成取件", "已在代收点取出", "已从代收点取出", "已从快递柜取出", "已从丰巢取出", "收件人已取件", "本人已取件", "客户已取件"].contains(where: clause.contains)
        }
    }
    private static func isConditional(_ latest: String) -> Bool {
        ["预计", "预估", "如果", "如已", "若已", "如您", "若您", "如有", "若有", "签收后", "取件后", "是否"].contains(where: latest.contains)
    }
    private static func factualClauses(_ latest: String) -> [String] {
        latest.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n")).filter { clause in
            !["尚未", "未签收", "未实际签收", "未取件", "未妥投", "未完成", "没有签收", "没有取件", "未能", "请确认"].contains(where: clause.contains)
        }
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
