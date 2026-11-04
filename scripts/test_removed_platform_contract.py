#!/usr/bin/env python3
"""Offline source contracts only: NOT Swift compilation, XCTest or device tests."""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return (ROOT / name).read_text()

class RemovedPlatformContract(unittest.TestCase):
    def test_removed_connector_has_no_executable_sources_or_tests(self):
        for folder, pattern in [('ParcelKeeper', 'JD*.swift'), ('ParcelKeeperTests', 'JD*.swift'), ('scripts', 'test_jd_*')]:
            self.assertEqual(list((ROOT / folder).rglob(pattern)), [])
        for folder in ['ParcelKeeper', 'ParcelKeeperTests']:
            text = '\n'.join(p.read_text() for p in (ROOT / folder).rglob('*.swift'))
            self.assertNotRegex(text, r'JDInAppClient|JDPCClient|JDLoggedError|JDDiagnostics|JDLoginPolicy|JDOrderImport|platform: \.jd|trade\.m\.jd\.com')
        self.assertIn('KDYZMSettingsView()', source('ParcelKeeper/Views/SettingsView.swift'))

    def test_unknown_source_cannot_fall_back_to_paid(self):
        route = source('ParcelKeeper/Services/TrackingRefreshService.swift')
        self.assertIn('guard shipment.originPlatform == nil', route)
        self.assertIn('throw TaobaoTrackingError.unsupported', route)
        self.assertIn('if mode == .uapi { return .uapi }', route)
        self.assertIn('if mode == .tmini { return .tmini }', route)
        self.assertIn('return .backend', route)

    def test_pdd_validation_precedes_save(self):
        view = source('ParcelKeeper/Views/MallImportView.swift')
        login = view.split('let cookies = try await browser.capture()', 1)[1].split('browser.destroy(); saved()', 1)[0]
        imported = view.split('private func saveImportedCookie()', 1)[1].split('private func safeFailure', 1)[0]
        self.assertLess(login.index('browser.verify(cookies)'), login.index('MallSession(platform: browser.platform).save(fresh, expectedGeneration: generation)'))
        self.assertLess(imported.index('.verifiedCookies()'), imported.index('MallSession(platform: currentPlatform).save(fresh, expectedGeneration: generation)'))
        verify = view.split('func verifiedCookies()', 1)[1].split('func fetchOrders()', 1)[0]
        self.assertIn('try await verifySession()', verify)
        self.assertIn('try await MallImportClient(platform: platform, cookies: cookies).verifySession()', view)
        self.assertIn('try await MallDirectClient(platform: platform, cookies: cookies).verifySession()', view)
        direct = source('ParcelKeeper/Services/MallDirectClient.swift')
        for token in ['PDDAccessToken', 'pdd_user_id', 'MallSession.applies', 'MallSession.valid',
                      'response.url == url', 'data.count <= 2_000_000', 'httpShouldHandleCookies = false',
                      'mobile.yangkeduo.com', 'rawData(content)', 'Task.checkCancellation()',
                      'MallDeliveryState.resolve', 'number == expected']:
            self.assertIn(token, direct)
        for token in ['testCookieIsolationAndHeaderInjection', 'testMissingCredentialsAuthVerificationRedirectAndSizeAreSafe',
                      'testPDDBindingMismatchAndMissingShippingIDDoNotGuess', 'testStrictAssignmentUnknownStructuresAndEmptyTrace']:
            self.assertIn(token, source('ParcelKeeperTests/MallDirectClientTests.swift'))

    def test_history_schema_storage_and_diagnostics_unchanged(self):
        # Authorized KDYZM adds only optional model metadata; old stored fields remain.
        model = source('ParcelKeeper/Models/Shipment.swift')
        old_model = subprocess.check_output(['git', 'show', 'HEAD:ParcelKeeper/Models/Shipment.swift'], cwd=ROOT).decode()
        old_fields = re.findall(r'^    var (\w+): (.+)$', old_model, re.M)
        for field, kind in old_fields:
            self.assertIn(f'    var {field}: {kind}', model)
        for field in ['backendBinding', 'backendEvents', 'backendLogisticsUpdatedAt', 'backendRefreshJobID', 'backendRefreshGeneration']:
            self.assertRegex(model, rf'    var {field}: [^\n]+\?')
        # Diagnostics may gain fixed allowlisted route events; storage and old platform client remain untouched.
        diagnostics = source('ParcelKeeper/Services/DiagnosticLog.swift')
        self.assertIn('let counts: [DiagnosticMetric: Int]', diagnostics)
        self.assertNotIn('let message: String', diagnostics)
        # Authorized follow-up now repairs import namespace and stale train buttons.
        # Preserve the original storage/migration/locking guarantees, not byte identity.
        storage = source('ParcelKeeper/Services/SharedPickupStore.swift')
        for token in ['func transaction', 'func snapshot', 'func previewBackup', 'func importBackup',
                      'validateImportIdentifiers(incoming, against: incoming)',
                      'validateImportIdentifiers(incoming, against: current)',
                      'binding == expectedBinding', 'LOCK_EX', '.atomic']:
            self.assertIn(token, storage)
        for name in ['ParcelKeeper/Services/TaobaoTrackingClient.swift']:
            before = subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT).decode()
            self.assertEqual(source(name), before, name)
        web = source('ParcelKeeper/Services/MallWebClient.swift')
        platform = web.split('enum MallPlatform', 1)[1].split('/// Preserve platform', 1)[0]
        self.assertIn('case pdd', platform)
        self.assertNotIn('case jd', platform)
        self.assertIn('ParcelKeeper.Mall.Web.\\(rawValue)', platform)
        for path in ['ParcelKeeper', 'ParcelKeeperTests']:
            self.assertIn('- path: ' + path, source('project.yml'))

if __name__ == '__main__':
    unittest.main()

