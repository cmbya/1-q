"""Source guards only; real Swift behavior is covered by RefreshOutcomeTests in CI."""
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
class RefreshOutcomes(unittest.TestCase):
    def test_queued_is_not_failed(self):
        s = (ROOT/'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
        self.assertIn('var queued: [Failure] = []', s)
        self.assertIn('report.queued.append', s)
        self.assertIn('catch KDYZMError.queued', s)
    def test_safe_routing_and_failure_diagnostics(self):
        s = (ROOT/'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
        d = (ROOT/'ParcelKeeper/Services/DiagnosticLog.swift').read_text()
        self.assertIn('trackingRouteBackend', d)
        self.assertIn('trackingRouteTmini', d)
        self.assertIn('trackingRouteUAPI', d)
        self.assertIn('static func diagnosticReason', s)
        self.assertIn('reason: Self.diagnosticReason(error)', s)
        self.assertIn('case .olderUpdate: return .olderEvent', s)
    def test_declared_channel_is_presented(self):
        s = (ROOT/'ParcelKeeper/Services/TrackingRefreshService.swift').read_text()
        self.assertIn('static func resolvedChannel', s)
        self.assertIn('static func routingDiagnostics', s)
        self.assertIn('routingDiagnostics(before, mode: mode)', s)
if __name__ == '__main__': unittest.main()
