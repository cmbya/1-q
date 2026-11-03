"""Source guard only; cancellation behaviour requires the accompanying XCTest on iOS."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class PreviewCancellationContract(unittest.TestCase):
    def test_url_cancel_is_not_converted_to_network_diagnostic(self):
        source = (ROOT / 'ParcelKeeper/Services/TaobaoTrial.swift').read_text()
        call = source.split('private func call(', 1)[1].split('func fetch()', 1)[0]
        self.assertIn('catch let error as URLError where error.code == .cancelled', call)
        self.assertLess(call.index('error.code == .cancelled'), call.index('let failure = error as NSError'))

if __name__ == '__main__': unittest.main()
