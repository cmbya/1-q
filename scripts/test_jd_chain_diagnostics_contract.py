"""Restricted source guards; not native Swift execution or real-account acceptance."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
class JDChainDiagnosticsContract(unittest.TestCase):
    def test_closed_filter_metrics_are_bounded(self):
        text = (ROOT / 'ParcelKeeper/Services/DiagnosticLog.swift').read_text()
        for metric in ['jdMissingDate', 'jdBusinessExcluded', 'jdOutsideWindow', 'jdDetailFailed', 'jdWithoutWaybill', 'jdLimited']:
            self.assertIn(metric, text)
        self.assertRegex(text, r'case [^\n]*\.jdLimited[^\n]*return min\(1, max\(0, value\)\)')
    def test_mobile_rotation_never_saves_pc_thor(self):
        text = (ROOT/'ParcelKeeper/Services/JDInAppClient.swift').read_text()
        body = text.split('@MainActor private func persistRotation',1)[1].split('enum JDPageParser',1)[0]
        self.assertIn('$0.name != "thor"', body)
    def test_mobile_query_preflight_stays_inside_diagnostic_operation(self):
        text = (ROOT / 'ParcelKeeper/Services/JDInAppClient.swift').read_text()
        query = text.split('    func query(orderID:',1)[1].split('    @MainActor private func operationStore',1)[0]
        self.assertLess(query.index('JDDiagnostics(.jdQuery'), query.index('let url = try JDPageParser.refreshURL'))
    def test_no_private_field_added_to_metric_api(self):
        text = (ROOT / 'ParcelKeeper/Services/DiagnosticLog.swift').read_text()
        metrics = text.split('enum DiagnosticMetric:')[1].split('enum DiagnosticLogStatus')[0]
        for forbidden in ['orderID', 'trackingNumber', 'cookieValue', 'responseText', 'sourceURL']:
            self.assertNotIn(forbidden, metrics)
if __name__ == '__main__':
    unittest.main()
