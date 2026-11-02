from pathlib import Path
root = Path(__file__).resolve().parents[1]
view = (root/'ParcelKeeper/Views/MallImportView.swift').read_text()
client = (root/'ParcelKeeper/Services/MallWebClient.swift').read_text()
login = view.split('let cookies = try await browser.capture()',1)[1].split('let fresh =',1)[0]
manual = view.split('let parsed: [TaobaoTrialCookie]',1)[1].split('try session.save(parsed)',1)[0]
verify = client.split('func verifySession() async throws {',1)[1].split('func fetchOrders()',1)[0]
assert 'MallWebClient' not in login, 'JD visible-login save still launches hidden order verification'
assert 'MallWebClient' not in manual, 'JD manual Cookie save still depends on order extraction'
assert 'observeOrders' not in verify, 'Session access verification still invokes courier selection'
assert 'JDOrderSelection' not in verify
assert 'MallWebParser.orders' not in verify
assert 'MallDirectClient' in login and 'MallDirectClient' in manual, 'PDD verification must stay intact'
assert '候选会话' in view
print('PASS: source contracts for both JD save entry points and independent session access; not Swift/device execution')
