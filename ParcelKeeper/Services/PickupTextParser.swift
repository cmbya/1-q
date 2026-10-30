import Foundation

/// Rule-based extraction only. Results are never authorization to save a record.
struct PickupTextParser {
    struct Candidate: Equatable {
        let code: String
        let location: String?
        let source: String?
        var requiresConfirmation: Bool { true }
    }

    struct Result: Equatable {
        let candidates: [Candidate]
        let isAmbiguous: Bool
        var requiresConfirmation: Bool { true }
    }

    func parse(_ input: String) -> Result {
        // SMS/OCR may use full-width or typographic hyphens inside the code,
        // not only after its label. Normalize before matching/protecting tokens.
        // Do not compatibility-normalize other characters or numeric identifiers.
        let text = input.replacingOccurrences(of: #"[－﹣‐‑‒–—−]"#,
                                              with: "-", options: .regularExpression)
        let full = NSRange(text.startIndex..., in: text)
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            return regex.matches(in: text, range: full)
        }
        func value(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        // Do not parse labels embedded in links or contact/order identifiers.
        let protected = matches(#"(?:https?://|www\.)[^\s，。；！？]+|(?:订单(?:号)?|运单(?:号)?|物流单(?:号)?|快递单(?:号)?|手机(?:号)?|电话(?:号)?)\s*[:：\-－—]?\s*(?:取件码|取货码|取餐码|提货码)?\s*[:：\-－—]?\s*[A-Za-z0-9+._/#*\-]+"#).map(\.range)
        let codeMatches = matches(#"(?:取件码|取货码|取餐码|提货码)\s*(?:是|为)?\s*[:：\-－—]?\s*((?>[A-Za-z0-9][A-Za-z0-9_#*+\-]*))(?![A-Za-z0-9_#*+\-])"#)
        let continuation = try? NSRegularExpression(pattern: #"\G\s*[,，、/;；]\s*((?>[A-Za-z0-9][A-Za-z0-9_#*+\-]*))(?![A-Za-z0-9_#*+\-\p{Han}])"#)
        var codes: [String] = []
        var codeOccurrences = 0
        for match in codeMatches {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let code = value(match, 1), code.count <= 32,
                  code.range(of: #"^1[3-9][0-9]{9}$"#, options: .regularExpression) == nil else { continue }
            codeOccurrences += 1
            if !codes.contains(code) { codes.append(code) }
            // Only consume a list item when it is a standalone token, never a
            // numeric prefix of an address such as “456号”.
            var position = NSMaxRange(match.range)
            while position < full.length,
                  let next = continuation?.firstMatch(in: text, options: [.anchored],
                                                      range: NSRange(location: position, length: full.length - position)),
                  !protected.contains(where: { NSIntersectionRange($0, next.range).length > 0 }),
                  let extra = value(next, 1), extra.count <= 32,
                  extra.range(of: #"^1[3-9][0-9]{9}$"#, options: .regularExpression) == nil {
                codeOccurrences += 1
                if !codes.contains(extra) { codes.append(extra) }
                position = NSMaxRange(next.range)
            }
        }
        let sources = matches(#"【([^【】\n]{1,30})】"#).compactMap { value($0, 1) }
            .filter { $0.range(of: #"(?:取件|取货|取餐|提货)码"#, options: .regularExpression) == nil }
        let locations = matches(#"(?:送达|至|到|地点\s*[:：]|地址\s*[:：])\s*([^，,。；;！!？?\n]+?)(?:取件|取货|取餐|领取|[，,。；;！!？?\n]|$)"#)
            .compactMap { value($0, 1)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Repeated occurrences may represent separate messages, even for identical values.
        let location = codeOccurrences == 1 && locations.count == 1 && sources.count <= 1 ? locations.first : nil
        let source = codeOccurrences == 1 && sources.count == 1 ? sources.first : nil
        return Result(candidates: codes.map { Candidate(code: $0, location: location, source: source) },
                      isAmbiguous: codeOccurrences > 1 || locations.count > 1 || sources.count > 1)
    }
}
