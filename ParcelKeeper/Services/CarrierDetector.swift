import Foundation

struct CarrierOption: Identifiable, Hashable {
    let id: String
    let name: String
    let code: String
}

struct CarrierDetection {
    let trackingNumber: String
    let carrier: CarrierOption
    let confidence: Double
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
        unknown
    ]

    private struct Rule {
        let carrier: CarrierOption
        let patterns: [String]
        let confidence: Double
    }

    private static let rules: [Rule] = [
        Rule(carrier: carrier("sf"), patterns: [#"^SF[0-9A-Z]{10,18}$"#], confidence: 0.99),
        Rule(carrier: carrier("jd"), patterns: [#"^(JD|JDX|JDL)[0-9A-Z]{8,20}$"#], confidence: 0.98),
        Rule(carrier: carrier("yto"), patterns: [#"^YT[0-9]{12,18}$"#], confidence: 0.98),
        Rule(carrier: carrier("jtexpress"), patterns: [#"^(JT|JTE)[0-9A-Z]{10,20}$"#], confidence: 0.98),
        Rule(carrier: carrier("ems"), patterns: [#"^[A-Z]{2}[0-9]{9}CN$"#], confidence: 0.99),
        Rule(carrier: carrier("sto"), patterns: [#"^(268|368|468|568|768|868|968)[0-9]{9,13}$"#], confidence: 0.82),
        Rule(carrier: carrier("yunda"), patterns: [#"^(43|44|45|46|47|48|49)[0-9]{11,15}$"#], confidence: 0.82),
        Rule(carrier: carrier("zto"), patterns: [#"^(5|7)[0-9]{11,15}$"#], confidence: 0.68),
        Rule(carrier: carrier("deppon"), patterns: [#"^[0-9]{8,10}$"#], confidence: 0.55)
    ]

    static func extractTrackingNumber(from rawText: String) -> String? {
        let uppercased = rawText.uppercased()
        let normalized = uppercased
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "：", with: ":")

        let pattern = #"[A-Z]{0,4}[0-9][A-Z0-9-]{7,27}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)

        let candidates = regex.matches(in: normalized, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range, in: normalized) else { return nil }
            let candidate = String(normalized[swiftRange])
                .replacingOccurrences(of: "-", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let digitCount = candidate.filter(\.isNumber).count
            guard candidate.count >= 8, candidate.count <= 28, digitCount >= 6 else { return nil }
            return candidate
        }

        return candidates.max { lhs, rhs in
            scoreCandidate(lhs) < scoreCandidate(rhs)
        }
    }

    static func detect(_ rawTrackingNumber: String) -> CarrierDetection {
        let trackingNumber = sanitize(rawTrackingNumber)

        for rule in rules {
            if rule.patterns.contains(where: { matches(trackingNumber, pattern: $0) }) {
                return CarrierDetection(
                    trackingNumber: trackingNumber,
                    carrier: rule.carrier,
                    confidence: rule.confidence
                )
            }
        }

        return CarrierDetection(
            trackingNumber: trackingNumber,
            carrier: unknown,
            confidence: 0.15
        )
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

    private static func scoreCandidate(_ value: String) -> Int {
        let detection = detect(value)
        return Int(detection.confidence * 1000) + value.count
    }
}
