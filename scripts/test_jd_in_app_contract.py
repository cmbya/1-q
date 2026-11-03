"""Offline source contracts; not a substitute for an iOS/WebKit build."""
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class JDContract(unittest.TestCase):
    def test_browser_boundary(self):
        source = (ROOT / 'ParcelKeeper/Services/JDInAppClient.swift').read_text()
        for token in ['verifySession()', 'fetchOrders()', 'query(orderID:', 'WKWebView', 'atDocumentStart', 'WeakHandler', 'Task.checkCancellation()', 'withTaskCancellationHandler', 'stopLoading()', 'removeScriptMessageHandler', 'cookie.webCookie()', 'deadline', 'isMainFrame']:
            self.assertIn(token, source)
        self.assertNotIn('URLSession', source)
        self.assertNotIn('UAPITrackingClient()', source)
        self.assertNotIn('document.cookie', source)
    def test_routes(self):
        source = (ROOT / 'ParcelKeeper/Services/MallWebClient.swift').read_text()
        self.assertIn('case jd', source)
        self.assertIn('JDInAppClient(cookies: cookies)', source)
        route = (ROOT / 'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
        self.assertIn('return .mall("jd")', route)
        self.assertNotIn('throw RemovedJDTrackingError.removed', route)
    def test_javascript(self):
        subprocess.run(['node', str(ROOT / 'scripts/test_jd_in_app_js.mjs')], check=True)

if __name__ == '__main__':
    unittest.main()
