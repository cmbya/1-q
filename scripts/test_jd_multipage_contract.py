from pathlib import Path
r=Path(__file__).resolve().parents[1]
c=(r/'ParcelKeeper/Services/MallWebClient.swift').read_text()
s=(r/'ParcelKeeper/Services/JDOrderSelection.swift').read_text()
assert 'JDOrderSelection.probes' in c, 'unknown type still blocked before detail'
assert 'window.scrollBy' in c, 'no page-generated pagination'
assert 'capturedOrderIDs' in c, 'no cross-page de-duplication'
assert '已到采集上限' in c, 'bounded partial results not disclosed'
assert 'JDOrderSelection.isRecentOrder' in c, 'month scope must be checked before import'
assert 'verifySession()' not in c.split('func fetchOrders()',1)[1].split('func query(',1)[0]
assert 'static func probes' in s
assert 'targetOrderID: orderID' in c and 'if let targetOrderID, collected.contains' in c
assert 'targetOrderID == nil ? 120 : 16' in c and 'addingTimeInterval(18)' in c
assert 'sourceURL: String? = nil' in c and 'logisticsURL(sourceURL, orderID: orderID)' in c
assert 'envelope["generation"] as? String == generation' in c
assert 'MallWebParser.jdRequestOrderID(packet.url) == expected' in c
assert 'excludedIDs.formUnion' in c and 'report.orders where !excludedIDs.contains(order.id)' in c
assert 'collected[index] = order' in c, 'DOM original link must replace synthesized fallback'
assert 'try? JDOrderSelection.inspectDOM' not in c, 'identity conflicts must not be swallowed'
assert 'rowURL' in s and 'rawRows.compactMap' in s
batch=(r/'ParcelKeeper/Services/MallCandidateBatch.swift').read_text()
assert 'orders.prefix(24)' in batch and 'result.candidates.count >= 8' in batch
assert 'JDOrderSelection.isRecentOrder' in c
assert 'static func detach' in c and 'static func removeData(from store:' in c
print('PASS source integration contracts (NOT Swift/device execution)')
