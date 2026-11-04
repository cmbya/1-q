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
    def test_no_legacy_executable_sources(self):
        files = list((ROOT / 'ParcelKeeper').rglob('*.swift'))
        text = '\n'.join(p.read_text() for p in files)
        for token in ['BaiduShortcut', 'baiduShortcut', 'JDWebScripts', 'JDOrderSelection',
                      'collectJDOrders', 'jdPackages', 'jdDOM', 'jdDetail']:
            # Match removed identifiers, not prefixes of new safe metrics (jdDetailFailed).
            self.assertIsNone(re.search(r'\b' + re.escape(token) + r'\b', text), token)
        self.assertNotIn('name: "mallResponse"', text)  # old broad bridge remains removed
        self.assertTrue((ROOT / 'ParcelKeeper/Services/JDInAppClient.swift').exists())
        self.assertIn('platform: .jd', source('ParcelKeeper/Views/SettingsView.swift'))

    def test_removed_route_cannot_charge_without_explicit_choice(self):
        service = source('ParcelKeeper/Services/TrackingRefreshService.swift')
        route = service.split('private static func route(', 1)[1].split('func setRefreshChannel', 1)[0]
        self.assertLess(route.index('mode == .uapi'), route.index('originPlatform == "jd"'))
        self.assertLess(route.index('refreshChannel == "uapi"'), route.index('originPlatform == "jd"'))
        self.assertIn('originPlatform == "jd" { return .mall("jd") }', route)
        self.assertNotIn('throw RemovedJDTrackingError.removed', route)
        web = source('ParcelKeeper/Services/MallWebClient.swift')
        client = web.split('struct MallTrackingClient', 1)[1].split('enum MallWebError', 1)[0]
        self.assertIn('JDInAppClient(cookies: cookies)', client)
        self.assertNotIn('UAPITrackingClient', client)
        tests = source('ParcelKeeperTests/MallRoutingTests.swift')
        for case in ['testJDDispatchesInAppConnectorWithoutPaidFallback',
                     'testJDInAppFailurePreservesHistoryAndNeverCharges',
                     'testExplicitUAPIOverrideAndModeRemainAvailable',
                     'testPDDDispatchWithoutPhoneOrUAPIFallback']:
            self.assertIn(case, tests)

    def test_pdd_validation_precedes_save(self):
        view = source('ParcelKeeper/Views/MallImportView.swift')
        login = view.split('let cookies = try await browser.capture()', 1)[1].split('browser.destroy(); saved()', 1)[0]
        imported = view.split('private func saveImportedCookie()', 1)[1].split('private func safeFailure', 1)[0]
        self.assertLess(login.index('browser.verify(cookies)'), login.index('MallSession(platform: browser.platform).save(fresh, expectedGeneration: generation)'))
        self.assertLess(imported.index('.verifiedCookies()'), imported.index('MallSession(platform: currentPlatform).save(fresh, expectedGeneration: generation)'))
        verify = view.split('func verifiedCookies()', 1)[1].split('func fetchOrders()', 1)[0]
        self.assertIn('try await verifySession()', verify)
        self.assertIn('try await MallImportClient(platform: platform, cookies: cookies).verifySession()', view)
        self.assertIn('case .pddDirect: try await MallDirectClient(platform: platform, cookies: cookies).verifySession()', view)
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
        old_diagnostics = subprocess.check_output(['git', 'show', 'HEAD:ParcelKeeper/Services/DiagnosticLog.swift'], cwd=ROOT).decode()
        old_cases = set(re.findall(r'^    case ([^\n]+)', old_diagnostics, re.M))
        for cases in old_cases:
            self.assertIn('    case ' + cases, diagnostics)
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
        self.assertIn('case jd', platform)  # newly authorized independent App-internal connector
        self.assertIn('ParcelKeeper.Mall.Web.\\(rawValue)', platform)
        for path in ['ParcelKeeper', 'ParcelKeeperTests']:
            self.assertIn('- path: ' + path, source('project.yml'))

if __name__ == '__main__':
    unittest.main()
