import Foundation

/// Profiles supply candidates, not permission. Every candidate must pass the
/// OS container lookup. All targets compile this same resolver.
enum AppGroupResolver {
    struct Candidate {
        let id: String
        let url: URL
        let hasData: Bool
        let selected: Bool
    }
    enum ResolutionError: LocalizedError {
        case chooseGroup, conflict, noAccess
        var errorDescription: String? {
            switch self {
            case .chooseGroup: return "请先到 设置 → 共享存储适配，确认使用哪个已授权共享组。"
            case .conflict: return "发现多个共享数据或选择标记，已停止读写。请先导出各组备份，不会自动切换或合并。"
            case .noAccess: return "签名未提供可访问的共享组。请检查全能签是否保留主 App 和组件的 App Group 权限；代码无法创建签名授权。"
            }
        }
    }
    private static let markerName = "parcelkeeper-selected-group-v1.json"
    static func profileGroups(_ data: Data) -> [String] {
        // CMS contains a signed XML plist. Extract only candidate IDs; this is
        // NOT signature verification and never substitutes for OS permission.
        guard data.count < 8_000_000,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return (entitlements["com.apple.security.application-groups"] as? [String] ?? [])
            .filter { $0.hasPrefix("group.") && !$0.contains("*") }
    }
    static func candidates(configured: String? = nil) throws -> [Candidate] {
        let bundle = Bundle.main
        let hostURL = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let host = bundle.bundleURL.pathExtension == "appex" ? Bundle(url: hostURL) : nil
        var ids = [configured, bundle.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String,
                   host?.object(forInfoDictionaryKey: "ParcelKeeperAppGroup") as? String].compactMap { $0 }
        for target in [bundle, host].compactMap({ $0 }) {
            if let url = target.url(forResource: "embedded", withExtension: "mobileprovision"),
               let bytes = try? Data(contentsOf: url) { ids += profileGroups(bytes) }
        }
        return try Array(Set(ids)).sorted().compactMap { id in
            guard id.hasPrefix("group."), !id.contains("*"),
                  let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
            let marker = url.appendingPathComponent("ParcelKeeper/" + markerName)
            var selected = false
            if FileManager.default.fileExists(atPath: marker.path) {
                let value = try JSONDecoder().decode(String.self, from: Data(contentsOf: marker))
                guard value == id else { throw ResolutionError.conflict }
                selected = true
            }
            let hasData = FileManager.default.fileExists(atPath: url.appendingPathComponent("ParcelKeeper/pickup-data.json").path)
            return Candidate(id: id, url: url, hasData: hasData, selected: selected)
        }
    }
    /// Pure policy, shared by app, shortcuts and widget; no arbitrary first group.
    static func selectedID(_ items: [Candidate]) throws -> String {
        let marked = items.filter { $0.selected }
        let existing = items.filter { $0.hasData }
        if marked.count > 1 || existing.count > 1 { throw ResolutionError.conflict }
        if let marked = marked.first {
            if let existing = existing.first, existing.id != marked.id { throw ResolutionError.conflict }
            return marked.id
        }
        // Preserve the only existing dataset, including older private builds.
        if let existing = existing.first { return existing.id }
        throw items.isEmpty ? ResolutionError.noAccess : ResolutionError.chooseGroup
    }
    static func container(configured: String? = nil) throws -> URL {
        let items = try candidates(configured: configured)
        let id = try selectedID(items)
        guard let item = items.first(where: { $0.id == id }) else { throw ResolutionError.noAccess }
        return item.url
    }
    static func choose(_ id: String) throws {
        let items = try candidates()
        guard let item = items.first(where: { $0.id == id }) else { throw ResolutionError.noAccess }
        // Once initialized, switching containers requires a separate migration.
        let occupied = items.filter { $0.hasData || $0.selected }
        guard occupied.allSatisfy({ $0.id == id }) else { throw ResolutionError.conflict }
        let directory = item.url.appendingPathComponent("ParcelKeeper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(markerName)
        try JSONEncoder().encode(id).write(to: file, options: .atomic)
        guard try selectedID(candidates()) == id else { throw ResolutionError.conflict }
    }
    static func groupID() throws -> String {
        try selectedID(candidates())
    }
}
