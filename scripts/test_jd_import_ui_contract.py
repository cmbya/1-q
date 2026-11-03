"""Offline source contracts, not proof of Swift compilation or live JD access."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text()


class JDImportUIContract(unittest.TestCase):
    def test_settings_adds_only_jd_without_replacing_working_entries(self):
        view = source('ParcelKeeper/Views/SettingsView.swift')
        self.assertIn('NavigationLink("京东导入（试验）") { MallImportView(platform: .jd) }', view)
        self.assertIn('NavigationLink("拼多多导入（试验）") { MallImportView(platform: .pdd) }', view)
        self.assertIn('NavigationLink("淘宝导入（试验）") { TaobaoTrialView() }', view)
        self.assertNotIn('Section("平台账号")', view)

    def test_dispatch_uses_jd_in_app_and_keeps_pdd_direct(self):
        view = source('ParcelKeeper/Views/MallImportView.swift')
        dispatch = view.split('struct MallImportClient {', 1)[1].split('/// Dedicated ephemeral browser', 1)[0]
        self.assertIn('platform == .jd ? .jdInApp : .pddDirect', dispatch)
        self.assertIn('JDInAppClient(cookies: cookies).verifySession()', dispatch)
        self.assertIn('JDInAppClient(cookies: cookies).fetchOrders()', dispatch)
        self.assertIn('MallDirectClient(platform: platform, cookies: cookies).verifySession()', dispatch)
        self.assertIn('MallDirectClient(platform: platform, cookies: cookies).fetchOrders()', dispatch)
        for method in ['verifySession', 'fetchOrders']:
            self.assertIn(f'case .jdInApp: {"return " if method == "fetchOrders" else ""}try await JDInAppClient(cookies: cookies).{method}()', dispatch)

    def test_login_and_cookie_import_validate_before_writing(self):
        view = source('ParcelKeeper/Views/MallImportView.swift')
        login = view.split('let cookies = try await browser.capture()', 1)[1].split('browser.destroy(); saved()', 1)[0]
        imported = view.split('private func saveImportedCookie()', 1)[1].split('private func safeFailure', 1)[0]
        self.assertIn('browser.verify(cookies)', login)
        self.assertIn('JDInAppClient(cookies: cookies, browserStore: web.configuration.websiteDataStore).verifySession()', view)
        self.assertIn('MallImportClient(platform: currentPlatform, cookies: parsed).verifiedCookies()', imported)
        for text, save in [(login, 'MallSession(platform: browser.platform).save(fresh, expectedGeneration: generation)'), (imported, 'save(fresh, expectedGeneration: generation)')]:
            self.assertLess(text.index('browser.verify(cookies)' if text is login else '.verifiedCookies()'), text.index(save))
            self.assertIn('Task.isCancelled' if text is login else 'Task.checkCancellation()', text)
        self.assertIn('MallImportClient(platform: currentPlatform, cookies: cookies).fetchOrders()', view)

    def test_jd_cookie_attributes_are_opt_in_and_cancel_does_not_save(self):
        view = source('ParcelKeeper/Views/MallImportView.swift')
        self.assertIn('if platform == .jd {', view)
        self.assertIn('if let value = cookie.webCookie()', view)
        self.assertIn('httpOnly: cookie.isHTTPOnly', view)
        # Existing PDD capture remains without the added attributes.
        self.assertIn('path: cookie.path, secure: cookie.isSecure, expires: cookie.expiresDate)', view)
        self.assertIn('Button("取消") { saveTask?.cancel(); browser.destroy(); dismiss() }', view)
        clear = view.split('private func clearSession()', 1)[1].split('private func fetch()', 1)[0]
        self.assertIn('MallSession(platform: currentPlatform).clear()', clear)
        self.assertIn('MallBrowserContext.detach(currentPlatform)', clear)
        self.assertNotIn('logout', clear.lower())

    def test_jd_only_guidance_and_manual_login(self):
        view = source('ParcelKeeper/Views/MallImportView.swift')
        self.assertIn('京东官方手机网页', view)
        self.assertIn('不会自动发送短信', view)
        self.assertIn('Button(platform == .jd ? "导入Cookie" : "导入Cookie（备用）")', view)
        self.assertIn('platform == .jd ? "清除本机京东会话" : "退出并清除本平台会话"', view)
        self.assertIn('拼多多使用已验证的Cookie直连读取，网页登录用于取得本机会话。', view)
        self.assertIn('mode: .platformOnly', view)
        self.assertIn('operationID == id', view)

    def test_taobao_login_ui_is_not_changed(self):
        diff = subprocess.run(['git', 'diff', '--', 'ParcelKeeper/Views/TaobaoTrialView.swift'], cwd=ROOT,
                              check=True, capture_output=True, text=True).stdout
        self.assertEqual(diff, '')


if __name__ == '__main__':
    unittest.main()
