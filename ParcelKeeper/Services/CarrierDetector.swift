import Foundation

struct CarrierOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let code: String
}

struct CarrierDetection: Identifiable, Sendable {
    let id: UUID
    let trackingNumber: String
    let carrier: CarrierOption
    let confidence: Double

    init(
        id: UUID = UUID(),
        trackingNumber: String,
        carrier: CarrierOption,
        confidence: Double
    ) {
        self.id = id
        self.trackingNumber = trackingNumber
        self.carrier = carrier
        self.confidence = confidence
    }
}

enum CarrierDetector {
    static let unknown = CarrierOption(id: "unknown", name: "暂未识别", code: "unknown")

    static let allCarriers: [CarrierOption] = [
        CarrierOption(id: "sf", name: "顺丰速运", code: "sf"),
        CarrierOption(id: "jd", name: "京东物流", code: "jd"),
        CarrierOption(id: "yto", name: "圆通速递", code: "yto"),
        CarrierOption(id: "zto", name: "中通快递", code: "zto"),
        CarrierOption(id: "sto", name: "申通快递", code: "sto"),
        CarrierOption(id: "yunda", name: "韵达速递", code: "yunda"),
        CarrierOption(id: "jtexpress", name: "极兔速递", code: "jtexpress"),
        CarrierOption(id: "ems", name: "EMS / 邮政", code: "ems"),
        CarrierOption(id: "deppon", name: "德邦快递", code: "deppon"),
        CarrierOption(id: "cainiao", name: "菜鸟裹裹", code: "cainiao"),
        CarrierOption(id: "best", name: "百世快递", code: "best"),
        CarrierOption(id: "kuaijiesudi", name: "快捷速递", code: "kuaijiesudi"),
        CarrierOption(id: "youzhengguonei", name: "邮政包裹", code: "youzhengguonei"),
        unknown
    ]

    private struct Rule {
        let carrier: CarrierOption
        let patterns: [String]
        let confidence: Double
    }

    private static let rules: [Rule] = [
        Rule(carrier: carrier("sf"), patterns: [#"^SF[0-9A-Z]{10,18}$"#], confidence: 0.99),
        Rule(carrier: carrier("jd"), patterns: [#"^(JD|JDX|JDL|VA)[0-9A-Z]{8,20}$"#], confidence: 0.98),
        Rule(carrier: carrier("yto"), patterns: [#"^YT[0-9]{10,20}$"#, #"^(D|G)[0-9]{12,18}$"#], confidence: 0.94),
        Rule(carrier: carrier("jtexpress"), patterns: [#"^(JT|JTE)[0-9A-Z]{10,20}$"#], confidence: 0.98),
        Rule(carrier: carrier("ems"), patterns: [#"^[A-Z]{2}[0-9]{9}CN$"#, #"^(10|11|50|51)[0-9]{11}$"#], confidence: 0.93),
        Rule(carrier: carrier("sto"), patterns: [#"^(268|368|468|568|768|868|968)[0-9]{9,13}$"#], confidence: 0.84),
        Rule(carrier: carrier("yunda"), patterns: [#"^(43|44|45|46|47|48|49)[0-9]{11,15}$"#], confidence: 0.84),
        Rule(carrier: carrier("zto"), patterns: [#"^(5|7)[0-9]{11,15}$"#], confidence: 0.70),
        Rule(carrier: carrier("deppon"), patterns: [#"^[0-9]{8,10}$"#], confidence: 0.56)
    ]

    private static let carrierKeywords: [(CarrierOption, [String])] = [
        (carrier("sf"), ["顺丰", "顺豐", "SF EXPRESS"]),
        (carrier("jd"), ["京东物流", "京東物流", "京东快递", "京東快遞"]),
        (carrier("yto"), ["圆通", "圓通", "YTO"]),
        (carrier("zto"), ["中通", "ZTO"]),
        (carrier("sto"), ["申通", "STO"]),
        (carrier("yunda"), ["韵达", "韻達"]),
        (carrier("jtexpress"), ["极兔", "極兔", "J&T"]),
        (carrier("ems"), ["EMS", "中国邮政", "中國郵政"]),
        (carrier("deppon"), ["德邦"]),
        (carrier("cainiao"), ["菜鸟", "菜鳥"]),
        (carrier("best"), ["百世"])
    ]

    static func extractTrackingNumber(from rawText: String) -> String? {
        extractTrackingNumbers(from: rawText).first
    }

    static func extractTrackingNumbers(from rawText: String, limit: Int = 12) -> [String] {
        let normalized = normalizeText(rawText)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let wholeLooksLikeNumber = isStandaloneCandidate(trimmed)

        let tokenPattern = #"(?<![A-Z0-9])(?:[A-Z]{1,5}[A-Z0-9]{7,27}|[0-9]{8,22})(?![A-Z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else { return [] }

        var scored: [(value: String, score: Int)] = []
        let lines = normalized.components(separatedBy: .newlines)

        for line in lines {
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in regex.matches(in: line, range: lineRange) {
                guard let swiftRange = Range(match.range, in: line) else { continue }
                let rawCandidate = String(line[swiftRange])
                let candidate = sanitize(rawCandidate)
                guard isPlausible(candidate) else { continue }

                var score = scoreCandidate(candidate)
                let upperLine = line.uppercased()

                if containsTrackingLabel(upperLine) { score += 650 }
                if upperLine.contains("物流") || upperLine.contains("快递") || upperLine.contains("快遞") { score += 180 }
                if upperLine.contains("订单号") || upperLine.contains("訂單號") || upperLine.contains("订单编号") { score -= 520 }
                if upperLine.contains("手机号") || upperLine.contains("联系电话") || upperLine.contains("電話") { score -= 900 }
                if upperLine.contains("身份证") || upperLine.contains("身份證") { score -= 1_200 }
                if isLikelyPhoneNumber(candidate) { score -= 1_100 }
                if wholeLooksLikeNumber && sanitize(trimmed) == candidate { score += 700 }

                scored.append((candidate, score))
            }
        }

        // 有些 App 复制出来不会保留换行，再对全文补扫一次。
        let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        for match in regex.matches(in: normalized, range: fullRange) {
            guard let swiftRange = Range(match.range, in: normalized) else { continue }
            let candidate = sanitize(String(normalized[swiftRange]))
            guard isPlausible(candidate) else { continue }
            var score = scoreCandidate(candidate)
            if wholeLooksLikeNumber && sanitize(trimmed) == candidate { score += 700 }
            scored.append((candidate, score))
        }

        var bestScoreByValue: [String: Int] = [:]
        for item in scored {
            bestScoreByValue[item.value] = max(bestScoreByValue[item.value] ?? Int.min, item.score)
        }

        return bestScoreByValue
            .filter { $0.value >= 250 }
            .sorted {
                if $0.value == $1.value { return $0.key.count > $1.key.count }
                return $0.value > $1.value
            }
            .prefix(limit)
            .map(\.key)
    }

    static func detect(_ rawTrackingNumber: String, context: String = "") -> CarrierDetection {
        let trackingNumber = sanitize(rawTrackingNumber)
        let mentioned = carrierMentioned(in: context)

        for rule in rules {
            if rule.patterns.contains(where: { matches(trackingNumber, pattern: $0) }) {
                if let mentioned, mentioned.id != rule.carrier.id {
                    return CarrierDetection(
                        trackingNumber: trackingNumber,
                        carrier: mentioned,
                        confidence: max(0.76, rule.confidence - 0.12)
                    )
                }
                return CarrierDetection(
                    trackingNumber: trackingNumber,
                    carrier: rule.carrier,
                    confidence: rule.confidence
                )
            }
        }

        if let mentioned {
            return CarrierDetection(
                trackingNumber: trackingNumber,
                carrier: mentioned,
                confidence: 0.90
            )
        }

        return CarrierDetection(
            trackingNumber: trackingNumber,
            carrier: unknown,
            confidence: 0.15
        )
    }

    static func carrierMentioned(in text: String) -> CarrierOption? {
        let upper = text.uppercased()
        for (carrier, keywords) in carrierKeywords {
            if keywords.contains(where: { upper.contains($0.uppercased()) }) {
                return carrier
            }
        }
        return nil
    }

    static func sanitize(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func carrier(_ id: String) -> CarrierOption {
        allCarriers.first(where: { $0.id == id }) ?? unknown
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func normalizeText(_ text: String) -> String {
        text
            .uppercased()
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func isStandaloneCandidate(_ value: String) -> Bool {
        let compact = sanitize(value)
        return compact.count >= 8 && compact.count <= 28 && compact.filter(\.isNumber).count >= 6
    }

    private static func isPlausible(_ value: String) -> Bool {
        let digitCount = value.filter(\.isNumber).count
        return value.count >= 8 && value.count <= 28 && digitCount >= 6
    }

    private static func isLikelyPhoneNumber(_ value: String) -> Bool {
        value.count == 11 && value.first == "1" && value.allSatisfy(\.isNumber)
    }

    private static func containsTrackingLabel(_ text: String) -> Bool {
        ["运单号", "運單號", "快递单号", "快遞單號", "物流单号", "物流單號", "快件号", "快件號", "TRACKING"].contains {
            text.contains($0.uppercased())
        }
    }

    private static func scoreCandidate(_ value: String) -> Int {
        let detection = detect(value)
        var score = Int(detection.confidence * 1_000) + min(value.count, 28)
        if value.first?.isLetter == true { score += 80 }
        if value.allSatisfy(\.isNumber), value.count >= 12 { score += 20 }
        return score
    }
}
