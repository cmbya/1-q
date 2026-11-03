"""Offline contracts only; native behaviour covered by unexecuted XCTest on Linux."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

def read(path): return (ROOT / path).read_text()

class JDCookieLoginContract(unittest.TestCase):
    def test_pc_cookie_import_and_preflight(self):
        parser = read('ParcelKeeper/Services/MallCookieImport.swift')
        session = read('ParcelKeeper/Services/MallWebClient.swift')
        self.assertNotIn('guard platform == .pdd else', parser)
        self.assertIn('platform == .jd ? ".jd.com" : ".yangkeduo.com"', parser)
        self.assertIn('hasJDPCSession(result)', parser)
        self.assertIn('static func hasJDPCSession', session)
        self.assertIn('$0.name == "thor"', session)
        self.assertIn('https://api.m.jd.com/api', session)

    def test_pc_protocol_is_bounded_and_routes_both_login_paths(self):
        path = ROOT / 'ParcelKeeper/Services/JDPCClient.swift'
        self.assertTrue(path.exists(), 'Missing PC-cookie order/logistics reader')
        source = path.read_text()
        for token in ['pcorder_center_list', 'pcdetail_traceMultiPackage', 'https://api.m.jd.com/api', 'AISecureNetwork()', 'httpShouldHandleCookies = false', '5 * 1024 * 1024', 'Task.checkCancellation()', 'jdOrdersParse', 'jdLogisticsParse', 'JDLoggedError', 'matches.count == 1', 'JDOrderImportPolicy.maxDetails', 'JDOrderImportPolicy.maxPages', 'response.url == url']:
            self.assertIn(token, source)
        wrapper = read('ParcelKeeper/Services/JDInAppClient.swift')
        self.assertEqual(wrapper.count('browserStore == nil && MallSession.hasJDPCSession(cookies)'), 3)
        self.assertNotIn('h5st', source)
        self.assertNotIn('UAPITrackingClient', source)

    def test_dual_entry_verifies_cookie_before_save_and_records_errors(self):
        source = read('ParcelKeeper/Views/MallImportView.swift')
        self.assertIn('platform == .jd ? "继续网页登录"', source)
        self.assertIn('Button("切换账号（全新手机网页）")', source)
        self.assertIn('platform == .jd ? "导入Cookie"', source)
        self.assertIn('含thor的电脑版', source)
        imported = source.split('private func saveImportedCookie()', 1)[1].split('private func safeFailure', 1)[0]
        self.assertIn('JDDiagnostics(.credential)', imported)
        self.assertIn('jdDiagnostics?.begin(.jdSessionSave)', imported)
        self.assertIn('jdDiagnostics?.fail(error)', imported)
        self.assertLess(imported.index('.verifiedCookies()'), imported.index('save(fresh, expectedGeneration: generation)'))
        self.assertIn('platform: currentPlatform, cookies: parsed', imported)
        self.assertIn('platform == currentPlatform', imported)
        self.assertIn('browser = MallLoginBrowser(platform: platform', source)

    def test_jd_resume_and_explicit_switch_use_isolated_mobile_context(self):
        source = read('ParcelKeeper/Views/MallImportView.swift')
        policy = read('ParcelKeeper/Services/JDLoginPolicy.swift')
        self.assertIn('platform == .jd ? WKWebsiteDataStore.nonPersistent()', source)
        self.assertIn('let loginCookies = jdPolicy?.cookies ?? cookies', source)
        self.assertIn('mode == .switchAccount', policy)
        self.assertIn('self.cookies = []; initialURL = MallPlatform.jd.loginURL', policy)
        self.assertIn('MallSession.hasJDPCSession(cookies)', policy)
        self.assertIn('initialURL = nil; pcSessionSaved = true', policy)
        self.assertIn('initialURL = valid ? MallPlatform.jd.ordersURL : MallPlatform.jd.loginURL', policy)
        self.assertIn('browser.verify(cookies)', source)
        self.assertIn('browser.commitJDContext()', source)
        client = read('ParcelKeeper/Services/JDInAppClient.swift')
        self.assertIn('browserStore == nil && MallSession.hasJDPCSession(cookies)', client)

    def test_pc_request_is_cancelled_at_operation_deadline(self):
        source = read('ParcelKeeper/Services/JDPCClient.swift')
        self.assertIn('withTaskCancellationHandler', source)
        self.assertIn('requestTask.cancel()', source)
        self.assertIn('deadlineTask.cancel()', source)
        self.assertIn('Task.sleep(nanoseconds:', source)

if __name__ == '__main__': unittest.main()
