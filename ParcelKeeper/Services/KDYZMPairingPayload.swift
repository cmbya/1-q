import Foundation
import CoreFoundation

enum KDYZMPairingScanError: LocalizedError {
    case invalid, multipleCodes
    var errorDescription: String? {
        switch self {
        case .invalid: return "不是受支持的后台绑定二维码。请使用后台生成的 HTTPS 绑定二维码，或手动填写。"
        case .multipleCodes: return "画面中有多个二维码，请只保留一个后台绑定二维码后重试。"
        }
    }
}

// Official raw JSON, not a URL/deep link. No networking or persistence here.
// zsdd2/kdyzm b13c0527cb38f3aad79cacf8ca85efacaa0004ed:
// src/service.mjs:147; src/store.mjs:215 generates 16 uppercase hex digits.
struct KDYZMPairingPayload: Equatable {
    let origin: String
    let code: String

    init(raw: String) throws {
        guard raw.utf8.count <= 4096,
              let bytes = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes),
              let json = object as? [String: Any],
              Set(json.keys) == Set(["schemaVersion", "baseUrl", "code"]),
              let version = json["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              // Reject fractional versions as well as bool/string coercions.
              version == NSNumber(value: 1),
              let base = json["baseUrl"] as? String,
              let code = json["code"] as? String,
              code.range(of: #"\A[A-F0-9]{16}\z"#, options: .regularExpression) != nil,
              let origin = try? KDYZMOrigin(base).value else {
            throw KDYZMPairingScanError.invalid
        }
        self.origin = origin
        self.code = code
    }

    static func single(_ values: [String]) throws -> Self {
        guard values.count == 1 else {
            throw values.isEmpty ? KDYZMPairingScanError.invalid : KDYZMPairingScanError.multipleCodes
        }
        guard let raw = values.first else { throw KDYZMPairingScanError.invalid }
        return try Self(raw: raw)
    }
}
