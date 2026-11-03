import Foundation

/// Latest timestamped event only. Deposit/agent signatures never imply recipient collection.
enum MallDeliveryState {
    static func resolve(latest: String) -> ShipmentStatus? {
        // Forecast/conditional scope may span commas; don't detach a positive clause from it.
        if ["预计", "预估", "如果", "如已", "若已", "如您", "若您", "如有", "若有", "签收后", "取件后", "是否"].contains(where: latest.contains) { return nil }
        let clauses = latest.components(separatedBy: CharacterSet(charactersIn: "，,。；;！!？?\n"))
        let facts = clauses.filter { clause in
            !["尚未", "未签收", "未实际签收", "未取件", "未妥投", "未完成", "没有签收", "没有取件", "未能", "请确认"].contains(where: clause.contains)
        }
        let collected = facts.contains { clause in
            // Requests are not collection facts, even when they name the recipient.
            guard !["请", "請", "待", "等待", "需", "须", "务必", "以便", "才能", "方可"].contains(where: clause.contains) else { return false }
            let recipientCollected = clause.range(of: #"(?:收件人|取件人|本人|客户)凭取件码完成取件"#, options: .regularExpression) != nil
            return recipientCollected || ["已完成取件", "已在代收点取出", "已从代收点取出", "已从快递柜取出", "已从丰巢取出", "收件人已取件", "本人已取件", "客户已取件"].contains(where: clause.contains)
        }
        if collected { return .delivered }
        let station = ["待取件", "等待取件", "待您领取", "请及时取件", "请尽快完成取件", "菜鸟驿站代收", "请凭码取件", "请凭取件码", "丰巢暂存", "快递柜暂存", "已放入快递柜", "已存入快递柜", "已送达菜鸟驿站", "已送达驿站", "已送达代收点", "驿站已签收", "代收点已签收", "已签收至菜鸟驿站"].contains(where: latest.contains)
        if station { return .readyForPickup }
        if facts.contains(where: { clause in ["已签收", "已妥投"].contains(where: clause.contains) }) { return .delivered }
        if facts.contains(where: { clause in ["正在派送", "正在配送", "派件中", "派送中", "配送中"].contains(where: clause.contains) }) { return .outForDelivery }
        if facts.contains(where: { clause in ["运输中", "已到达转运中心", "已到达中转", "已离开转运中心", "已揽收", "已揽件", "快递员已取件"].contains(where: clause.contains) }) { return .inTransit }
        return nil
    }
}
