import Foundation

enum SmartShipmentParser {
    static func parse(_ rawText: String) -> [ShipmentImportDraft] {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let numbers = CarrierDetector.extractTrackingNumbers(from: text)
        guard !numbers.isEmpty else { return [] }

        let sharedPickupCode = extractPickupCode(from: text)
        let sharedStatus = inferStatus(from: text)
        let sharedNote = inferNote(from: text)

        return numbers.map { number in
            let localContext = context(around: number, in: text)
            let detection = CarrierDetector.detect(number, context: localContext.isEmpty ? text : localContext)

            return ShipmentImportDraft(
                trackingNumber: detection.trackingNumber,
                carrier: detection.carrier,
                confidence: detection.confidence,
                status: sharedStatus,
                note: sharedNote,
                pickupCode: sharedPickupCode
            )
        }
    }

    static func parseSingleNumber(_ value: String) -> ShipmentImportDraft? {
        let normalized = CarrierDetector.sanitize(value)
        guard normalized.count >= 8 else { return nil }
        let detection = CarrierDetector.detect(normalized)
        return ShipmentImportDraft(
            trackingNumber: detection.trackingNumber,
            carrier: detection.carrier,
            confidence: detection.confidence
        )
    }

    private static func extractPickupCode(from text: String) -> String {
        let pattern = #"(?:取件码|取件碼|提货码|提貨碼|取货码|取貨碼|凭证码|憑證碼|核销码|核銷碼)\s*[：:为為是]?\s*([A-Z0-9]{2,5}(?:[-－][A-Z0-9]{2,6}){0,2}|[A-Z0-9]{3,12})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "" }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else { return "" }
        return String(text[swiftRange]).replacingOccurrences(of: "－", with: "-")
    }

    private static func inferStatus(from text: String) -> ShipmentStatus {
        if containsAny(text, ["已签收", "已簽收", "签收成功", "簽收成功", "已收货", "已收貨"]) {
            return .delivered
        }
        if containsAny(text, ["待取件", "请取件", "請取件", "已到驿站", "已到快递柜", "已到快遞櫃", "取件码", "取件碼"]) {
            return .readyForPickup
        }
        if containsAny(text, ["派送中", "配送中", "正在派送", "正在配送", "快递员派送", "快遞員派送"]) {
            return .outForDelivery
        }
        if containsAny(text, ["物流异常", "物流異常", "运输异常", "運輸異常", "退回", "滞留", "滯留", "拒收"]) {
            return .exception
        }
        return .inTransit
    }

    private static func inferNote(from text: String) -> String {
        var parts: [String] = []

        if containsAny(text, ["拼多多", "PINDUODUO"]) {
            parts.append("拼多多")
        } else if containsAny(text, ["京东", "京東", "JD.COM"]) {
            parts.append("京东")
        } else if containsAny(text, ["淘宝", "淘寶", "天猫", "天貓", "TMALL"]) {
            parts.append("淘宝/天猫")
        }

        if let product = firstCapturedGroup(
            in: text,
            pattern: #"(?:商品|宝贝|寶貝|物品|订单内容|訂單內容|商品名称|商品名稱)\s*[：:]\s*([^\n\r，。；;]{2,40})"#
        ) {
            parts.append(cleanNotePart(product))
        }

        if containsAny(text, ["菜鸟驿站", "菜鳥驛站"]) {
            parts.append("菜鸟驿站")
        } else if containsAny(text, ["丰巢", "豐巢"]) {
            parts.append("丰巢快递柜")
        } else if containsAny(text, ["快递柜", "快遞櫃"]) {
            parts.append("快递柜")
        } else if containsAny(text, ["驿站", "代收点", "代收點"]) {
            parts.append("驿站/代收点")
        }

        return parts.prefix(3).joined(separator: " · ")
    }

    private static func context(around number: String, in text: String) -> String {
        let upperText = text.uppercased()
        guard let range = upperText.range(of: number.uppercased()) else { return "" }
        let start = upperText.index(range.lowerBound, offsetBy: -80, limitedBy: upperText.startIndex) ?? upperText.startIndex
        let end = upperText.index(range.upperBound, offsetBy: 80, limitedBy: upperText.endIndex) ?? upperText.endIndex
        return String(upperText[start..<end])
    }

    private static func containsAny(_ text: String, _ values: [String]) -> Bool {
        let upper = text.uppercased()
        return values.contains { upper.contains($0.uppercased()) }
    }

    private static func firstCapturedGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func cleanNotePart(_ value: String) -> String {
        value
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
