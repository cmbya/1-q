import Foundation

enum SmartShipmentParser {
    static func parse(_ rawText: String) -> [ShipmentImportDraft] {
        let text = PickupFieldProtection.singleNotification(rawText)
        guard !text.isEmpty else { return [] }

        let numbers = ShipmentShortcutParser.numbers(in: text)
        guard !numbers.isEmpty else { return [] }
        let contexts: [String]
        if numbers.count == 1 {
            contexts = [text]
        } else {
            // Only explicit blank-line blocks or self-contained single lines
            // establish parcel ownership. Never use overlapping character windows.
            let blocks = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            func isolated(_ parts: [String]) -> Bool {
                let ids = parts.map { ShipmentShortcutParser.numbers(in: $0) }
                return ids.allSatisfy { $0.count == 1 } && ids.count == numbers.count && Set(ids.flatMap { $0 }) == Set(numbers)
            }
            if isolated(blocks) { contexts = blocks }
            else if isolated(lines) { contexts = lines }
            else { return [] }
        }
        return contexts.compactMap { context in
            guard let parsed = try? ShipmentShortcutParser.parse(context) else { return nil }
            let detection = CarrierDetector.detect(parsed.trackingNumber, context: context)
            // Pickup codes in historical events must not be reused on a newer
            // return/delivery. For dated histories inspect only the selected event.
            let codeContext = parsed.logisticsTime == nil ? context : (parsed.logisticsInfo ?? context)
            return ShipmentImportDraft(
                trackingNumber: parsed.trackingNumber,
                carrier: detection.carrier,
                confidence: detection.confidence,
                status: parsed.status ?? .inTransit,
                note: inferNote(from: context),
                pickupCode: parsed.status == .readyForPickup ? extractPickupCode(from: codeContext) : ""
            )
        }
    }

    static func parseSingleNumber(_ value: String) -> ShipmentImportDraft? {
        guard let normalized = try? ShipmentShortcutParser.number(value) else { return nil }
        let detection = CarrierDetector.detect(normalized)
        return ShipmentImportDraft(
            trackingNumber: detection.trackingNumber,
            carrier: detection.carrier,
            confidence: detection.confidence
        )
    }

    private static func extractPickupCode(from input: String) -> String {
        let text = PickupFieldProtection.singleNotification(input)
            .replacingOccurrences(of: #"[－﹣‐‑‒–—−]"#, with: "-", options: .regularExpression)
        let pattern = #"(?:取件码|取件碼|提货码|提貨碼|取货码|取貨碼|凭证码|憑證碼|核销码|核銷碼)\s*[：:为為是]?\s*((?>"# + PickupFieldProtection.tokenPattern + "))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "" }
        let protected = PickupFieldProtection.ranges(in: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            !protected.contains { NSIntersectionRange($0, match.range(at: 1)).length > 0 }
        }
        guard matches.count == 1, let match = matches.first,
              let span = Range(match.range(at: 1), in: text) else { return "" }
        let code = String(text[span])
        // Preserve the existing plain/hyphen length limits, extending only the
        // supported in-code symbols. Never shorten an unsupported whole token.
        guard code.range(of: #"^(?:[A-Za-z0-9_#*+]{1,5}(?:-[A-Za-z0-9_#*+]{1,6}){1,2}|[A-Za-z0-9_#*+]{3,12})$"#, options: .regularExpression) != nil,
              PickupFieldProtection.allows(code, range: match.range(at: 1), protected: protected),
              PickupFieldProtection.isWholeToken(match.range(at: 1), in: text, labeled: true),
              !PickupFieldProtection.hasAdjacentListItem(to: match.range(at: 1), in: text) else { return "" }
        return code
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
