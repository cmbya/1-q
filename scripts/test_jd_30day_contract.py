"""Source contracts supplement, never replace, uncompiled native XCTest definitions."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class JDThirtyDayContract(unittest.TestCase):
    def test_shared_policy_report_and_calendar_window(self):
        s = (ROOT / 'ParcelKeeper/Services/JDOrderImportPolicy.swift').read_text()
        for token in ['struct JDOrderImportReport', 'struct JDOrderImportPolicy', 'Asia/Shanghai', 'value: -29', 'value: 1', 'missingDate', 'withoutWaybill', 'outsideWindow', 'limited', '暂无法生成快递']:
            self.assertIn(token, s)
    def test_both_clients_have_report_compatibility_and_no_pending_cap(self):
        for name in ['JDPCClient.swift', 'JDInAppClient.swift']:
            s = (ROOT / 'ParcelKeeper/Services' / name).read_text()
            self.assertIn('func fetchOrderReport() async throws -> JDOrderImportReport', s)
            self.assertIn('try await fetchOrderReport().candidates', s)
            self.assertNotIn('prefix(8)', s)
            self.assertNotIn('filter(\\.pending)', s)
            self.assertNotIn('filter(\\.importable)', s)
            self.assertIn('now: () -> Date', s)
    def test_pc_protocol_pagination_budget_and_timeout_partial(self):
        s = (ROOT / 'ParcelKeeper/Services/JDPCClient.swift').read_text()
        for token in ['maxPages', 'maxDetails', 'totalNum', 'dateSubmit', 'limited = true', 'JDOrderImportPolicy.isTimeout', 'seen.insert', 'page: page']:
            self.assertIn(token, s)
        self.assertNotIn('logisticsDOM', s)
    def test_mobile_remains_honestly_limited_and_missing_date_is_not_verification(self):
        s = (ROOT / 'ParcelKeeper/Services/JDInAppClient.swift').read_text()
        self.assertIn('report.limited = true', s)
        self.assertIn('submittedAt', s)
        self.assertIn('logisticsEmpty', s)
        self.assertNotIn('logisticsDOM', s)
        verify = s.split('func verifySession()',1)[1].split('func fetchOrders()',1)[0]
        self.assertNotIn('fetchOrderReport', verify)
        self.assertNotIn('contains(', verify)

if __name__ == '__main__': unittest.main()
