"""Offline SOURCE contracts only; never executes Swift/XCTest/Keychain/network.
Native behavioral regression definitions live in JDPCClientTests/JDOrderImportPolicyTests.
"""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
POLICY = (ROOT / 'ParcelKeeper/Services/JDOrderImportPolicy.swift').read_text()
PC = (ROOT / 'ParcelKeeper/Services/JDPCClient.swift').read_text()

class JDPCPolicyRepairsSourceContracts(unittest.TestCase):
    def test_explicit_service_business_not_bare_service_substring(self):
        body = POLICY.split('static func excluded(', 1)[1].split('static func isTimeout', 1)[0]
        self.assertNotIn('"服务"', body)
        for label in ['"服务订单"', '"生活服务"', '"虚拟业务"']:
            self.assertIn(label, body)

    def test_detail_failure_unread_and_safe_stop_are_separate(self):
        for token in ['var detailFailed = 0', 'var stoppedReason: DiagnosticReason?', 'var unreadDetails: Int', 'recordDetailFailure(orderID:', 'private var failedOrders', 'private var ambiguousNumbers']:
            self.assertIn(token, POLICY)
        self.assertNotIn('candidates.first(where:', POLICY)
        self.assertIn('candidates.removeAll', POLICY)
        self.assertIn('previewDetail: parcel', POLICY)

    def test_summary_has_closed_count_categories(self):
        for metric in ['jdMissingDate', 'jdBusinessExcluded', 'jdOutsideWindow', 'jdDetailFailed', 'jdWithoutWaybill', 'jdLimited']:
            self.assertIn('.' + metric + ':', POLICY)
        self.assertIn('reason: stoppedReason', POLICY)

    def test_field_fallback_conflict_guard_and_detail_recovery(self):
        self.assertIn('nestedCarriage', PC)
        self.assertIn('outerNumber', PC)
        self.assertIn('nestedNumber', PC)
        self.assertIn('outerNumber != nestedNumber', PC)
        self.assertIn('report.recordDetailFailure(orderID: order.id)', PC)
        self.assertIn('report.stoppedReason = reason', PC)
        self.assertIn('guard report.stoppedReason == nil', PC)
        self.assertNotIn('guard JDOrderImportPolicy.isTimeout(error) else { throw error }', PC)
        self.assertNotIn('row["createTime"]', PC)
        self.assertNotIn('error.localizedDescription', PC)

if __name__ == '__main__':
    unittest.main()
