import Foundation
import CoreFoundation

/// Independently implemented from protocol observations in Granter-z/parcly,
/// 0e4c7739205b368ab9bed3299f963a3e6fd9cf91, jd_delivery_filter/jd_trace_parser
/// and jd_connector (originOrderStatus, orderType, wareInfoList.skuId, shopInfo.shopId).
/// No demonstrated JSON order-date field: recent-month API rows must be supplemented
/// by a visible, identity-bound DOM snapshot rather than guessing createTime.
enum JDOrderSelection {
    enum SkipReason: String, Hashable {
        case unknownType, nonCourier, excludedStatus, unknownDate, outsideWindow, missingLink
    }
    struct Report {
        var orders: [MallWebOrder] = []
        var skipped: [SkipReason: Int] = [:]
        // Unknown delivery type/link is unresolved, not proof of an empty courier list.
        var requiresDOM: Bool {
            [SkipReason.unknownType, .unknownDate, .missingLink].contains { skipped[$0, default: 0] > 0 }
        }
        mutating func skip(_ reason: SkipReason) { skipped[reason, default: 0] += 1 }
    }
    private static func scalar(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        // JSON booleans are NSNumber too; never use them as identifiers/parameters.
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }
    private static func identifier(_ id: String) -> Bool {
        id.range(of: #"^[0-9]{6,32}$"#, options: .regularExpression) != nil
    }
    private static func numericParameter(_ value: Any?) -> String? {
        guard let text = scalar(value), text.range(of: #"^[0-9]{1,32}$"#, options: .regularExpression) != nil else { return nil }
        return text
    }
    /// Preserve the exact original absolute HTTPS string (including protocol parameters).
    /// Only normalize root-relative and protocol-relative links, never other hostnames.
    static func logisticsURL(_ raw: String, orderID: String) throws -> URL {
        guard identifier(orderID), raw.utf8.count <= 8192,
              !raw.contains(where: { $0.isWhitespace || $0.isNewline }), !raw.contains("\\") else { throw MallWebError.identityMismatch }
        let text: String
        if raw.hasPrefix("//") { text = "https:" + raw }
        else if raw.hasPrefix("/") { text = "https://trade.m.jd.com" + raw }
        else { text = raw }
        guard let c = URLComponents(string: text), c.scheme == "https", c.host == "trade.m.jd.com",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              c.percentEncodedPath == "/order/deal_wuliu_jdm.shtml", c.fragment == nil,
              let q = c.queryItems, q.filter({ $0.name == "dealId" }).map(\.value) == [Optional(orderID)],
              q.filter({ $0.name.lowercased() == "dealid" }).count == 1,
              let url = c.url else { throw MallWebError.identityMismatch }
        let alternate = q.filter { $0.name.lowercased() == "orderid" }
        guard alternate.count <= 1, alternate.allSatisfy({ $0.value == orderID }) else { throw MallWebError.identityMismatch }
        return url
    }
    private static func excluded(_ text: String) -> Bool {
        ["取消", "关闭", "退款", "待付款", "未支付", "未付款"].contains(where: text.contains)
    }
    private static func fallback(_ object: [String: Any], id: String) -> URL? {
        guard let status = object["orderStatusInfo"] as? [String: Any],
              let state = numericParameter(status["originOrderStatus"]),
              let type = numericParameter(object["orderType"]),
              let shop = object["shopInfo"] as? [String: Any], let shopID = numericParameter(shop["shopId"]),
              let goods = object["wareInfoList"] as? [[String: Any]], let first = goods.first,
              let sku = numericParameter(first["skuId"]) else { return nil }
        var c = URLComponents(string: "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml")!
        c.queryItems = [.init(name: "from", value: "orderdetail"), .init(name: "dealState", value: state),
                        .init(name: "dealId", value: id), .init(name: "orderType", value: type),
                        .init(name: "skuid", value: sku), .init(name: "shopid", value: shopID),
                        .init(name: "source", value: "m_inner_orderList.track_orderTrack")]
        return c.url
    }
    static func orders(root: [String: Any], now: Date = Date(), recentMonth: Bool = true) throws -> [MallWebOrder] {
        try inspect(root: root, now: now, recentMonth: recentMonth).orders
    }
    static func inspect(root: [String: Any], now: Date = Date(), recentMonth: Bool = true) throws -> Report {
        guard let body = root["body"] as? [String: Any], let rows = body["orderList"] as? [[String: Any]], rows.count <= 200 else { throw MallWebError.unsupported }
        var report = Report()
        var seen = Set<String>()
        for object in rows {
            guard let id = scalar(object["orderId"]), identifier(id), seen.insert(id).inserted else { throw MallWebError.identityMismatch }
            let status = (object["orderStatusInfo"] as? [String: Any])?["orderStatusName"] as? String ?? ""
            if excluded(status) { report.skip(.excludedStatus); continue }
            guard let progress = object["progressInfo"] as? [String: Any], let type = progress["progressId"] as? String, !type.isEmpty else { report.skip(.unknownType); continue }
            guard type == "logistics" else { report.skip(.nonCourier); continue }
            let url: URL
            if let value = progress["progressLink"] {
                guard let link = value as? String else { throw MallWebError.unsupported }
                if link.isEmpty {
                    guard let made = fallback(object, id: id) else { report.skip(.missingLink); continue }
                    url = made
                } else { url = try logisticsURL(link, orderID: id) }
            } else {
                guard let made = fallback(object, id: id) else { report.skip(.missingLink); continue }
                url = made
            }
            // No credible order-date key in the pinned source. Never infer from trace times.
            if recentMonth { report.skip(.unknownDate); continue }
            let title = (object["wareInfoList"] as? [[String: Any]])?.first?["wareName"] as? String ?? "京东订单"
            report.orders.append(MallWebOrder(id: id, title: String(title.prefix(200)), url: url))
        }
        return report
    }
    /// Probe eligibility is not courier classification or permission to import.
    /// ExpressAssistant b8925655 uses order fields when progressInfo is absent.
    static func probes(_ root: [String: Any]) throws -> [MallWebOrder] {
        guard let body = root["body"] as? [String: Any], let rows = body["orderList"] as? [[String: Any]], rows.count <= 200 else { throw MallWebError.unsupported }
        var result: [MallWebOrder] = []
        for row in rows {
            guard let id = scalar(row["orderId"]), identifier(id) else { throw MallWebError.identityMismatch }
            let status = (row["orderStatusInfo"] as? [String: Any])?["orderStatusName"] as? String ?? ""
            if excluded(status) { continue }
            let specials = row["specialDealList"] as? [[String: Any]] ?? []
            if specials.contains(where: { ($0["isStore2Home"] as? Bool) == true }) { continue }
            let raw = (row["progressInfo"] as? [String: Any])?["progressLink"] as? String ?? ""
            let url: URL
            if !raw.isEmpty { url = try logisticsURL(raw, orderID: id) }
            else if let built = fallback(row, id: id) { url = built }
            else { continue }
            let title = (row["wareInfoList"] as? [[String: Any]])?.first?["wareName"] as? String ?? "京东订单"
            if !result.contains(where: { $0.id == id }) { result.append(MallWebOrder(id: id, title: String(title.prefix(200)), url: url)) }
        }
        return result
    }
    static func isRecentOrder(text: String, now: Date = Date()) throws -> Bool {
        let dates = labeledDates(text)
        guard dates.count == 1, let date = orderDate(dates[0]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        guard let cutoff = calendar.date(byAdding: .month, value: -1, to: now) else { throw MallWebError.unsupported }
        return date >= cutoff && date <= now
    }
    private static func labeledDates(_ text: String) -> [String] {
        let pattern = #"(?:下单时间|下单日期)\s*[:：]?\s*(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?)(?![\d:])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
    private static func orderDate(_ text: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.isLenient = false
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: text), f.string(from: d) == text { return d }
        }
        return nil
    }
    static func ordersDOM(_ value: Any, now: Date = Date(), recentMonth: Bool = true) throws -> [MallWebOrder] {
        try inspectDOM(value, now: now, recentMonth: recentMonth).orders
    }
    static func inspectDOM(_ value: Any, now: Date = Date(), recentMonth: Bool = true) throws -> Report {
        guard let root = value as? [String: Any], root["recognized"] as? Bool == true,
              let empty = root["empty"] as? Bool, let rows = root["rows"] as? [[String: Any]], rows.count <= 200,
              (!rows.isEmpty && !empty) || (rows.isEmpty && empty) else { throw MallWebError.unsupported }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        guard let cutoff = calendar.date(byAdding: .month, value: -1, to: now) else { throw MallWebError.unsupported }
        var report = Report(); var seen = Set<String>()
        for row in rows {
            guard let id = row["id"] as? String, identifier(id), seen.insert(id).inserted,
                  let raw = row["url"] as? String, let text = row["text"] as? String, text.utf8.count <= 32000,
                  let title = row["title"] as? String, let dateText = row["orderDate"] as? String else { throw MallWebError.identityMismatch }
            let url = try logisticsURL(raw, orderID: id)
            let regex = try! NSRegularExpression(pattern: #"订单(?:编号|号)\s*[:：]?\s*([0-9]{6,32})(?![0-9])"#)
            let ns = text as NSString
            let ids = Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
            guard ids == Set([id]) else { throw MallWebError.identityMismatch }
            // Restrict status exclusion to status-like lines, not product titles.
            let statusLines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            let excludedStatus = statusLines.contains { line in
                line.range(of: #"^(?:订单状态\s*[:：]?\s*)?(?:已取消|已关闭|交易关闭|订单取消|订单关闭|待付款|未支付|未付款|退款中|已退款|退款成功|退款完成)$"#, options: .regularExpression) != nil
            }
            if excludedStatus { report.skip(.excludedStatus); continue }
            if recentMonth {
                let dates = labeledDates(text)
                guard dates.count == 1, dates.first == dateText, let date = orderDate(dateText) else { report.skip(.unknownDate); continue }
                guard date >= cutoff, date <= now else { report.skip(.outsideWindow); continue }
            }
            report.orders.append(MallWebOrder(id: id, title: String(title.prefix(200)), url: url))
        }
        return report
    }

    /// WKWebView evaluateJavaScript returns this bounded object directly (not a JSON string).
    /// Fail closed on unfamiliar/unfinished pages; do not infer identity from body text.
    static let domScript: String = #"""
    (() => {
      const result = {recognized:false, empty:false, rows:[]};
      if (location.hostname !== 'trade.m.jd.com' || location.pathname !== '/order/orderlist_jdm.shtml') return result;
      const visible = e => {
        for (let n=e; n; n=n.parentElement) {
          const s=getComputedStyle(n);
          if (n.hidden || s.display==='none' || s.visibility==='hidden' || s.visibility==='collapse' || s.opacity==='0' || !n.getClientRects().length) return false;
        }
        return true;
      };
      const parse = href => {
        if (!href || href.length>8192 || /[\s\\]/.test(href)) return null;
        let u; try { u=new URL(href, 'https://trade.m.jd.com/order/orderlist_jdm.shtml'); } catch (_) { return null; }
        if(u.protocol!=='https:' || u.hostname!=='trade.m.jd.com' || u.port && u.port!=='443' || u.username || u.password || u.hash || u.pathname!=='/order/deal_wuliu_jdm.shtml') return null;
        const ids=u.searchParams.getAll('dealId');
        if(ids.length!==1 || !/^[0-9]{6,32}$/.test(ids[0])) return null;
        const aliases=[...u.searchParams].filter(([k])=>k.toLowerCase()==='dealid');
        const orderIDs=[...u.searchParams].filter(([k])=>k.toLowerCase()==='orderid');
        if(aliases.length!==1 || orderIDs.length>1 || orderIDs.some(([,v])=>v!==ids[0])) return null;
        // Absolute URLs retain their original query ordering/encoding.
        const original=href.startsWith('//')?'https:'+href:href.startsWith('/')?'https://trade.m.jd.com'+href:href;
        if(!original.startsWith('https://')) return null;
        return {id:ids[0],url:original};
      };
      const anchors=Array.from(document.querySelectorAll('a[href]'));
      if(anchors.length>2000) return result;
      const rows=[], seen=new Set(); let ambiguous=false;
      for(const a of anchors) {
        if(!visible(a)) continue;
        const p=parse(a.getAttribute('href')); if(!p) continue;
        let card=null;
        for(let n=a.parentElement, depth=0; n && n!==document.body && n!==document.documentElement && depth<12; n=n.parentElement,depth++) {
          const text=n.innerText || '';
          if(text.length>16000) break;
          const ids=[...text.matchAll(/订单(?:编号|号)\s*[:：]?\s*([0-9]{6,32})(?![0-9])/g)].map(m=>m[1]);
          if(!ids.length) continue;
          const distinct=new Set(ids);
          if(distinct.size!==1 || !distinct.has(p.id)) break;
          const links=Array.from(n.querySelectorAll('a[href]')).filter(visible).map(e=>parse(e.getAttribute('href'))).filter(Boolean);
          if(links.some(l=>l.id!==p.id)) break;
          card=n; break;
        }
        if(!card) continue;
        if(seen.has(p.id)) { ambiguous=true; continue; }
        seen.add(p.id);
        const text=card.innerText || '';
        const dates=[...text.matchAll(/(?:下单时间|下单日期)\s*[:：]?\s*(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?)(?![\d:])/g)];
        const lines=text.split(/\n/).map(s=>s.trim()).filter(Boolean);
        const title=lines.find(s=>!/(订单(?:编号|号)|下单时间|下单日期|查看物流|已签收|已完成)/.test(s)) || '京东订单';
        rows.push({id:p.id,url:p.url,text,title:title.slice(0,200),orderDate:dates.length===1?dates[0][1]:''});
        if(rows.length>200) return result;
      }
      if(ambiguous) return result;
      if(rows.length) return {recognized:true,empty:false,rows};
      // Explicit, visible empty marker on the exact orders route only. No body-wide
      // text substring inference; a still-loading/unknown layout is unsupported.
      const nodes=Array.from(document.querySelectorAll('*'));
      if(nodes.length<=5000 && nodes.some(n=>visible(n) && /^(暂无订单|您还没有相关订单|没有相关订单)$/.test((n.innerText||'').trim()))) return {recognized:true,empty:true,rows:[]};
      return result;
    })()
    """#
}
