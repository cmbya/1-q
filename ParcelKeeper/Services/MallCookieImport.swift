// Legacy direct marketplace import is opt-in; source is retained for restoration.
#if ENABLE_DIRECT_MALL_IMPORT
import Foundation

/// Import only a Cookie header value, never a curl command, URL or arbitrary headers.
enum MallCookieImport {
    static func parse(_ text: String, platform: MallPlatform) throws -> [TaobaoTrialCookie] {
        guard !text.isEmpty, text.utf8.count < 90_000,
              text.utf8.allSatisfy({ (32...126).contains($0) }) else { throw MallWebError.authentication }
        var names = Set<String>()
        var result: [TaobaoTrialCookie] = []
        let segments = text.split(separator: ";", omittingEmptySubsequences: false)
        for (index, raw) in segments.enumerated() {
            let segment = raw.trimmingCharacters(in: .whitespaces)
            if segment.isEmpty && index == segments.count - 1 { continue }
            guard let equal = segment.firstIndex(of: "=") else { throw MallWebError.authentication }
            let name = String(segment[..<equal])
            let value = String(segment[segment.index(after: equal)...])
            guard !name.isEmpty, name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [95,45].contains($0) }),
                  names.insert(name).inserted, !value.contains(" "), !value.contains("\""), !value.contains("\\"), !value.contains(",") else { throw MallWebError.authentication }
            result.append(.init(name: name, value: value, domain: ".yangkeduo.com", path: "/", secure: true, expires: nil))
        }
        guard MallSession.hasLoginCredentials(result, platform: platform) else { throw MallWebError.authentication }
        return result
    }
}
#endif
