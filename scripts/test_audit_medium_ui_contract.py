#!/usr/bin/env python3
"""Offline source/regex contracts only. Does not execute Swift or XCTest."""
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]
def source(name):
    return (ROOT / 'ParcelKeeper' / name).read_text()
class MediumContracts(unittest.TestCase):
    def test_reconnect_reconciles_and_reports(self):
        store = source('Services/ShipmentStore.swift').split('func reconnectSharedStorage', 1)[1].split('// Call when', 1)[0]
        self.assertIn('async throws -> [String]', store)
        self.assertIn('guard !reminderOperationInProgress', store)
        self.assertLess(store.index('apply(data)'), store.index('await reconcileReminders()'))
        view = source('Views/SharedStorageSettingsView.swift')
        self.assertIn('try await store.reconnectSharedStorage()', view)
        self.assertIn('warnings.joined', view)
        self.assertIn('operationID == operation', view)
        self.assertIn('.onDisappear', view)
        self.assertIn('.disabled(connecting)', view)
    def test_cookie_validation_precedes_expiry_filter(self):
        text = source('Services/MallWebClient.swift')
        valid = text.split('static func valid(', 1)[1].split('static func hasLoginCredentials', 1)[0]
        self.assertIn('structurallyValid', valid)
        self.assertIn('CharacterSet.controlCharacters.contains', valid)
        load = text.split('func load()', 1)[1].split('func save(', 1)[0]
        self.assertLess(load.index('Self.structurallyValid'), load.index('cookies.filter'))
        self.assertIn('Self.hasLoginCredentials(active', load)
        self.assertIn('return active', load)
    def test_browser_initialization_is_stoppable(self):
        text = source('Views/TaobaoTrialView.swift')
        self.assertIn('initializationTask = Task', text)
        self.assertIn('initializationTask?.cancel()', text)
        initialization = text.split('initializationTask = Task', 1)[1].split('func webView', 1)[0]
        self.assertIn('guard !self.stopped, !Task.isCancelled', initialization)
        self.assertIn('self.web.load(', initialization)
        self.assertIn('.onDisappear { browser.stop() }', text)
        self.assertIn('coordinator.stop()', text)
    def test_order_timestamp_same_line_date_split_time(self):
        text = source('Services/TrainTicketRecognition.swift')
        def extract(pattern):
            match = re.search(pattern, text)
            assert match is not None, pattern
            return match[1]
        names = extract(r'nonTravelTimeNames = "(.*?)"')
        day = extract(r'let day = #"(.*?)"#')
        time = extract(r'let time = #"(.*?)"#')
        # Extract literal Swift regex concatenation rather than maintaining another implementation.
        expr = text.split('let splitTimestamp = ', 1)[1].split('return fieldLines', 1)[0]
        pieces = re.findall(r'#"(.*?)"#|"((?:[^"\\]|\\.)*)"|\b(nonTravelTimeNames|day|time)\b', expr, re.S)
        pattern = ''.join(raw or (bytes(normal, 'utf8').decode('unicode_escape') if normal else {'nonTravelTimeNames': names, 'day': day, 'time': time}[variable]) for raw, normal, variable in pieces)
        for label in ['下单时间', '支付日期', '出票时间', '购票时间']:
            for sep in ['', '\n', '\r\n']:
                value = label + '：' + sep + '2026-10-31\n08:12:34\n出发日期：2027-01-01\n车次：G123\n发车时间：09:00'
                evidence = re.sub(pattern, '', value)
                self.assertNotIn('08:12', evidence)
                self.assertNotIn('2026-10-31', evidence)
                self.assertIn('2027-01-01', evidence)
                self.assertIn('G123', evidence)
                self.assertIn('09:00', evidence)
        for value in ['2026-10-31\n08:12', '下单时间：2026-10-31\n出发时间：08:12', '下单时间：2026-10-31\n北京南 08:12']:
            self.assertIn('08:12', re.sub(pattern, '', value))
if __name__ == '__main__':
    unittest.main(verbosity=2)
