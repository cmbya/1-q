"""Source-contract checks only, NOT Swift compilation or XCTest execution. No network."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class TminiContract(unittest.TestCase):
    def text(self, file): return (ROOT / file).read_text()
    def test_client_contract(self):
        s = self.text('ParcelKeeper/Services/TminiTrackingClient.swift')
        for needle in ['https://api.tmini.net/apis/autonumber', 'URLQueryItem(name: "key"', 'URLQueryItem(name: "trackingNo"', 'TminiSecureNetwork()', '2_000_000', 'validateConfiguration', 'packageInfoList', 'Asia/Shanghai', '0000000000']:
            self.assertIn(needle, s)
        for needle in ['configuration.httpCookieStorage = nil', 'configuration.urlCache = nil', 'configuration.timeoutIntervalForResource = 15', 'session.bytes(for: request)', 'body.count < 2_000_000', 'AIRedirectGuard()']:
            self.assertIn(needle, s)
        guard = self.text('ParcelKeeper/Services/AIService.swift').split('final class AIRedirectGuard')[1].split('final class AISecureNetwork')[0]
        self.assertIn('completionHandler(nil)', guard)
        for needle in ['UAPIUsage', 'recordUsage', 'forHTTPHeaderField: "Authorization"', 'name: "phone"', 'http://']:
            self.assertNotIn(needle, s)
    def test_routing_and_phone_isolation(self):
        s = self.text('ParcelKeeper/Services/TrackingRefreshService.swift')
        for needle in ['case automatic, platformOnly, uapi, tmini', 'if mode == .tmini { return .tmini }', 'shipment.refreshChannel == "tmini"', '(try? Self.route(before, mode: mode)) == .backend', 'case .tmini:', 'tminiClient.query(trackingNumber: number)', 'blockedPlatforms.insert("tmini")', 'validateConfiguration']:
            self.assertIn(needle, s)
        branch = s.split('private static func route(')[1].split('func setRefreshChannel')[0]
        self.assertLess(branch.index('if mode == .tmini { return .tmini }'), branch.index('return .backend'))
        self.assertLess(branch.index('if mode == .uapi { return .uapi }'), branch.index('return .backend'))
        branch = s.split('case .tmini:')[-1].split('case .uapi:')[0]
        self.assertNotIn('phones.', branch)
    def test_ui_and_intents(self):
        self.assertIn('TminiSettingsView()', self.text('ParcelKeeper/Views/SettingsView.swift'))
        self.assertIn('SecureField', self.text('ParcelKeeper/Views/TminiSettingsView.swift'))
        self.assertIn('case .tmini: return .tmini', self.text('ParcelKeeper/Intents/TrackingRefreshIntents.swift'))
        self.assertIn('Text("Tmini").tag("tmini")', self.text('ParcelKeeper/Views/ShipmentDetailView.swift'))
        self.assertTrue((ROOT / 'docs/TMINI-TRACKING.md').is_file())
if __name__ == '__main__': unittest.main()

