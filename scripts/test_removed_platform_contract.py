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
                      'pcorder_center_', 'api.m.jd.com', 'plogin.m.jd.com',
                      'collectJDOrders', 'jdPackages', 'jdDOM', 'jdDetail']:
            self.assertNotIn(token, text, token)
        self.assertNotIn('name: "mallResponse"', text)  # diagnostic event names remain compatible
        self.assertFalse(list(ROOT.glob('scripts/test_jd_*')))
        self.assertFalse(list(ROOT.glob('ParcelKeeperTests/JD*Tests.swift')))
        self.assertNotIn('platform: .jd', source('ParcelKeeper/Views/SettingsView.swift'))

    def test_removed_route_cannot_charge_without_explicit_choice(self):
        service = source('ParcelKeeper/Services/TrackingRefreshService.swift')
        route = service.split('private static func route(', 1)[1].split('func setRefreshChannel', 1)[0]
        self.assertLess(route.index('mode == .uapi'), route.index('originPlatform == "jd"'))
        self.assertLess(route.index('refreshChannel == "uapi"'), route.index('originPlatform == "jd"'))
        self.assertIn('originPlatform == "jd" { throw RemovedJDTrackingError.removed }', route)
        self.assertNotIn('.mall("jd")', route)
        self.assertIn('latest.originPlatform != "jd"', service)  # batch reports removal, not silent skip
        web = source('ParcelKeeper/Services/MallWebClient.swift')
        client = web.split('struct MallTrackingClient', 1)[1].split('enum MallWebError', 1)[0]
        self.assertLess(client.index('throw RemovedJDTrackingError.removed'), client.index('MallSession('))
        self.assertIn('旧京东直连已移除，请接入后台或明确选择UAPI', web)
        tests = source('ParcelKeeperTests/MallRoutingTests.swift')
        for case in ['testRemovedJDNeverDispatchesAndPreservesHistory',
                     'testRemovedJDClientBoundaryFailsBeforeCredentials',
                     'testExplicitUAPIOverrideAndModeRemainAvailable',
                     'testPDDDispatchWithoutPhoneOrUAPIFallback']:
            self.assertIn(case, tests)

    def test_pdd_validation_precedes_save(self):
        view = source('ParcelKeeper/Views/MallImportView.swift')
        login = view.split('let cookies = try await browser.capture()', 1)[1].split('browser.destroy(); saved()', 1)[0]
        imported = view.split('private func saveImportedCookie()', 1)[1].split('private func safeFailure', 1)[0]
        for body, save in [(login, 'MallSession(platform: browser.platform).save'), (imported, 'session.save(parsed)')]:
            self.assertLess(body.index('.verifySession()'), body.index(save))
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
        for name in ['ParcelKeeper/Services/SharedPickupStore.swift',
                     'ParcelKeeper/Services/DiagnosticLog.swift',
                     'ParcelKeeper/Services/TaobaoTrackingClient.swift']:
            before = subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=ROOT).decode()
            self.assertEqual(source(name), before, name)
        web = source('ParcelKeeper/Services/MallWebClient.swift')
        platform = web.split('enum MallPlatform', 1)[1].split('/// Preserve platform', 1)[0]
        self.assertIn('case pdd', platform)
        self.assertNotIn('jd', platform)
        self.assertIn('ParcelKeeper.Mall.Web.\\(rawValue)', platform)
        for path in ['ParcelKeeper', 'ParcelKeeperTests']:
            self.assertIn('- path: ' + path, source('project.yml'))

if __name__ == '__main__':
    unittest.main()
