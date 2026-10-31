import Foundation

/// Shared provenance, whole-token and structural multiplicity protection.
/// Entry points retain their own label semantics and compatible length limits.
/// Ranges always refer to the exact text supplied by the caller (UTF-16 for Foundation).
enum PickupFieldProtection {
    private static let pattern = #"(?:https?://|www\.)[^\s，。；！？]+|(?:(?:订单|訂單|运单|運單|物流单|物流單|快递单|快遞單|手机|手機|电话|電話)(?:号码|號碼|编号|編號|号|號)?|单(?:号码|號碼|编号|編號|号|號)|單(?:号码|號碼|编号|編號|号|號))\s*[:：\-－﹣‐‑‒–—−]?\s*(?:取件码|取件碼|取货码|取貨碼|取餐码|取餐碼|提货码|提貨碼|凭证码|憑證碼|核销码|核銷碼)?\s*(?:是|为|為)?\s*[:：\-－﹣‐‑‒–—−]?\s*[A-Za-z0-9+._/#*\-－﹣‐‑‒–—−]+"#

    static let tokenPattern = #"[A-Za-z0-9][A-Za-z0-9_#*+\-－﹣‐‑‒–—−]*"#

    static func singleNotification(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"\A(.+?)(?:\s+\1)+\z"#, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else { return trimmed }
        return String(trimmed[range])
    }

    // A dot is a sentence terminator only when it does not join another token.
    // URL/identifier punctuation must never authorize extracting a short prefix.
    static func isWholeToken(_ range: NSRange, in text: String, labeled: Bool = false) -> Bool {
        guard let span = Range(range, in: text) else { return false }
        let joined = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_#*+-－﹣‐‑‒–—−/@?=&%:")
        if span.lowerBound > text.startIndex && !labeled {
            let before = text[text.index(before: span.lowerBound)]
            if before == "." || before.unicodeScalars.contains(where: { joined.contains($0) }) { return false }
        }
        if span.upperBound < text.endIndex {
            let after = text[span.upperBound]
            if after.unicodeScalars.contains(where: { joined.contains($0) }) { return false }
            if after == "." {
                let next = text.index(after: span.upperBound)
                if next < text.endIndex && text[next].unicodeScalars.contains(where: { joined.contains($0) }) { return false }
            }
        }
        return true
    }

    // Structural list evidence only, including unlabeled model-selected codes.
    // A numeric address prefix (456号楼) is not another standalone code.
    static func hasAdjacentListItem(to range: NSRange, in text: String) -> Bool {
        guard let span = Range(range, in: text) else { return false }
        let item = "(?>" + tokenPattern + ")(?![A-Za-z0-9_#*+\\-－﹣‐‑‒–—−\\p{Han}])"
        let suffix = String(text[span.upperBound...])
        let prefix = String(text[..<span.lowerBound])
        let protected = ranges(in: text)
        func validItem(_ part: String, pattern: String, offset: Int) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)),
                  let captured = Range(match.range(at: 1), in: part) else { return false }
            let candidate = NSRange(location: offset + match.range(at: 1).location, length: match.range(at: 1).length)
            return allows(String(part[captured]), range: candidate, protected: protected)
                && isWholeToken(candidate, in: text)
        }
        return validItem(suffix, pattern: #"^\s*[,，、/;；]\s*("# + item + ")", offset: range.location + range.length)
            || validItem(prefix, pattern: "(" + item + #")\s*[,，、/;；]\s*$"#, offset: 0)
    }

    static func ranges(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    static func allows(_ code: String, range: NSRange, protected: [NSRange]) -> Bool {
        !protected.contains { NSIntersectionRange($0, range).length > 0 }
            && code.range(of: #"^1[3-9][0-9]{9}$"#, options: .regularExpression) == nil
    }
}

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
        // Collapse only exact repetitions of the entire notice, never globally
        // unique codes/locations or repeated lines inside different messages.
        let notice = PickupFieldProtection.singleNotification(input)
        let text = notice.replacingOccurrences(of: #"[－﹣‐‑‒–—−]"#,
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
        let protected = PickupFieldProtection.ranges(in: text)
        let codeMatches = matches(#"(?:取件码|取货码|取餐码|提货码)\s*(?:是|为)?\s*[:：\-－—]?\s*((?>[A-Za-z0-9][A-Za-z0-9_#*+\-]*))(?![A-Za-z0-9_#*+\-])"#)
        let continuation = try? NSRegularExpression(pattern: #"\G\s*[,，、/;；]\s*((?>[A-Za-z0-9][A-Za-z0-9_#*+\-]*))(?![A-Za-z0-9_#*+\-\p{Han}])"#)
        var codes: [String] = []
        var codeOccurrences = 0
        for match in codeMatches {
            guard let code = value(match, 1), code.count <= 32,
                  PickupFieldProtection.isWholeToken(match.range(at: 1), in: text, labeled: true),
                  PickupFieldProtection.allows(code, range: match.range(at: 1), protected: protected) else { continue }
            codeOccurrences += 1
            if !codes.contains(code) { codes.append(code) }
            // Only consume a list item when it is a standalone token, never a
            // numeric prefix of an address such as “456号”.
            var position = NSMaxRange(match.range)
            while position < full.length,
                  let next = continuation?.firstMatch(in: text, options: [.anchored],
                                                      range: NSRange(location: position, length: full.length - position)),
                  let extra = value(next, 1), extra.count <= 32,
                  PickupFieldProtection.isWholeToken(next.range(at: 1), in: text, labeled: true),
                  PickupFieldProtection.allows(extra, range: next.range(at: 1), protected: protected) {
                codeOccurrences += 1
                if !codes.contains(extra) { codes.append(extra) }
                position = NSMaxRange(next.range)
            }
        }
        let sources = matches(#"【([^【】\n]{1,30})】"#).compactMap { value($0, 1) }
            .filter { $0.range(of: #"(?:取件|取货|取餐|提货)码"#, options: .regularExpression) == nil }
        let locations = matches(#"(?:送达|至|到|地点\s*[:：]|地址\s*[:：])\s*([^，,。；;！!？?\n]+?)(?:包裹待签收|取件|取货|取餐|领取|【|[，,。；;！!？?\n]|$)"#)
            .compactMap { value($0, 1)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Repeated occurrences may represent separate messages, even for identical values.
        let location = codeOccurrences == 1 && locations.count == 1 && sources.count <= 1 ? locations.first : nil
        let source = codeOccurrences == 1 && sources.count == 1 ? sources.first : nil
        return Result(candidates: codes.map { Candidate(code: $0, location: location, source: source) },
                      isAmbiguous: codeOccurrences > 1 || locations.count > 1 || sources.count > 1)
    }
}
