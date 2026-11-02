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
print('PASS source integration contracts (NOT Swift/device execution)')
