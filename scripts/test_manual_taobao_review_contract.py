#!/usr/bin/env python3
"""Offline source contracts: not Swift compilation or runtime tests."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

def source(path):
    return (ROOT / 'ParcelKeeper' / path).read_text()

class ManualTaobaoReviewContracts(unittest.TestCase):
    def test_manual_validation_and_save_share_strict_raw_parser(self):
        text = source('Views/AddShipmentSheet.swift')
        self.assertIn('var validatedTrackingNumber: String?', text)
        self.assertIn('try? ShipmentShortcutParser.number(trackingNumber)', text)
        self.assertIn('.disabled(validatedTrackingNumber == nil || isSaving)', text)
        save = text.split('private func saveShipment()', 1)[1]
        self.assertIn('guard let normalized = validatedTrackingNumber', save)
        self.assertLess(save.index('guard let normalized'), save.index('let shipment = Shipment('))
        self.assertNotIn('CarrierDetector.sanitize', text)
        self.assertIn('try? ShipmentShortcutParser.number(value)', text)

    def test_diagnostic_only_exact_known_codes(self):
        text = source('Services/TaobaoTrialDiagnostic.swift')
        self.assertNotIn('safeBusinessCode', text)
        self.assertIn('return allowed.contains(code) ? code : "未识别返回码"', text)
        allowed = set(re.findall(r'"([A-Z_]+)"', text.split('let allowed:', 1)[1].split('let raw', 1)[0]))
        for known in ['SUCCESS', 'FAIL_SYS_SESSION_EXPIRED', 'FAIL_SYS_USER_VALIDATE', 'FAIL_BIZ_ORDER_NOT_FOUND']:
            self.assertIn(known, allowed)
        for secret in ['ERROR_SECRET_COOKIE_ABCDEF', 'FAIL_SECRET_TOKEN_ABCDEF', 'FAIL_BIZ_ORDER_NOT_FOUND_SECRET']:
            self.assertNotIn(secret, allowed)

    def test_batch_applies_remaining_budget_to_running_request(self):
        text = source('Views/TaobaoTrialView.swift').split('private func importSelected(', 1)[1]
        self.assertIn('guard !busy, !store.isHistoricalSnapshot', text)
        self.assertIn('let remaining = 20 - (ProcessInfo.processInfo.systemUptime - started)', text)
        self.assertLess(text.index('store.importTaobao(candidate)'), text.index('let remaining'))
        self.assertIn('!platformStopped, remaining > 0', text)
        self.assertIn('let request = Task { @MainActor in', text)
        self.assertIn('Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))', text)
        self.assertIn('withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })', text)
        self.assertGreaterEqual(text.count('deadline.cancel()'), 2)
        self.assertNotIn('catch is CancellationError { return }', text)
        self.assertIn('guard !Task.isCancelled, operationID == id else { return }', text)
        self.assertIn('try? store.reload()', text)
        self.assertIn('未调用UAPI。', text)

if __name__ == '__main__':
    unittest.main(verbosity=2)
