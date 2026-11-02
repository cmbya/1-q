#!/usr/bin/env python3
"""Source contracts only; not a Swift compilation or device/runtime test."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DiagnosticLogContractTests(unittest.TestCase):
    def setUp(self):
        self.service = (ROOT / 'ParcelKeeper/Services/DiagnosticLog.swift').read_text()
        self.view = (ROOT / 'ParcelKeeper/Views/DiagnosticLogView.swift').read_text()
        self.tests = (ROOT / 'ParcelKeeperTests/DiagnosticLogTests.swift').read_text()

    def test_no_arbitrary_event_or_error_payload(self):
        self.assertRegex(self.service, r'func record\(_ event: DiagnosticEvent')
        self.assertIn('reason: DiagnosticReason? = nil', self.service)
        self.assertIn('counts: [DiagnosticMetric: Int] = [:]', self.service)
        for forbidden in ['localizedDescription', 'URLSession', 'HTTPCookie', 'identifierForVendor', 'UIDevice']:
            self.assertNotIn(forbidden, self.service)
        self.assertNotRegex(self.service, r'func record\([^\n]*(?:String|Data)')

    def test_storage_is_bounded_private_serial_and_protected(self):
        for token in ['maximumEntries = 500', 'maximumBytes = 512 * 1024', '.applicationSupportDirectory',
                      'DispatchQueue(label:', 'queue.async', '.isExcludedFromBackupKey',
                      '.completeUntilFirstUserAuthentication', '.atomic', 'operationAliases']:
            self.assertIn(token, self.service)
        self.assertIn('data.count <= Self.maximumBytes', self.service)
        self.assertIn('fileSize <= Self.maximumBytes', self.service)
        self.assertIn('removeItem(at: exportDirectory)', self.service)

    def test_view_explicit_controls_and_errors(self):
        for token in ['Toggle(', 'ShareLink(', 'UIPasteboard', '.confirmationDialog(',
                      'log.clear', 'log.refresh', 'log.export', 'snapshot.status', 'snapshot.issue',
                      '本应用无法删除', 'expirationDate']:
            self.assertIn(token, self.view)

    def test_swift_cases_exist_for_runtime_suite(self):
        for token in ['testMissingIsNotCorruption', 'testRotationAndMetricClamping',
                      'testDisabledSurvivesRestart', 'testCorruptDoesNotSilentlyOverwrite',
                      'testIOFailureIsNotMissing', 'testConcurrentWriters',
                      'testExportProtectionAndClearRemovesExports', 'testOversizedFile']:
            self.assertIn(token, self.tests)

if __name__ == '__main__':
    unittest.main()
