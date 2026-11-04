"""Static source contracts only. Does not compile or execute Swift. No network."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class UsageContract(unittest.TestCase):
    def test_dispatch_boundary(self):
        s = (ROOT/'ParcelKeeper/Services/TminiTrackingClient.swift').read_text()
        query = s.split('func query(trackingNumber: String) async throws -> UAPITrackingResult {')[1].split('static func parse')[0]
        self.assertEqual(query.count('usage.recordDispatch()'), 1)
        self.assertLess(query.index('configurationToken()'), query.index('usage.recordDispatch()'))
        self.assertLess(query.index('validateConfiguration(token)'), query.index('usage.recordDispatch()'))
        self.assertLess(query.index('usage.recordDispatch()'), query.index('network.data(for: request)'))
        self.assertIn('.accounting: return true', s)
    def test_persistence_and_privacy(self):
        s = (ROOT/'ParcelKeeper/Services/TminiUsageStore.swift').read_text()
        for text in ['queries * 4', 'flock(fd, LOCK_EX | LOCK_NB)', 'flock(fd, LOCK_UN)', 'options: .atomic', 'AppGroupResolver.container()', 'NSFileReadNoSuchFileError', 'Int64.max / 4']:
            self.assertIn(text,s)
        model = s.split('struct TminiUsageSummary:')[1].split('final class')[0]
        for text in ['key:', 'trackingNumber', 'URL', 'secret']:
            self.assertNotIn(text, model)
        self.assertNotIn('try? JSONDecoder', s)
    def test_ui_disclosure_and_tests(self):
        s = (ROOT/'ParcelKeeper/Views/TminiSettingsView.swift').read_text()
        for text in ['累计查询次数','累计记账积分','本地估算，不代表平台余额','刷新记账显示（不查询）','loadUsage()', 'scenePhase']:
            self.assertIn(text,s)
        t = (ROOT/'ParcelKeeperTests/TminiUsageTests.swift').read_text()
        for text in ['concurrentPerform', 'testCorruptionIsPreservedAndOverflowRejected', 'testOnlyDispatchCountsIncludingFailuresAndCredentialReplacement']:
            self.assertIn(text,t)
if __name__ == '__main__': unittest.main()

