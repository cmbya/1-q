"""Static safety regression checks; not a substitute for XCTest/device verification."""
import pathlib
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]

class PairingQRContract(unittest.TestCase):
    def test_real_camera_and_permission(self):
        camera = (ROOT / 'ParcelKeeper/Views/KDYZMScannerView.swift').read_text()
        for required in ['AVCaptureSession', 'AVCaptureMetadataOutput', 'requestAccess', 'stopRunning', 'scenePhase', 'metadataObjectTypes = [.qr]', '[weak self]']:
            self.assertIn(required, camera)
        self.assertIn('NSCameraUsageDescription', (ROOT / 'project.yml').read_text())

    def test_parser_is_offline_and_strict(self):
        parser = (ROOT / 'ParcelKeeper/Services/KDYZMPairingPayload.swift').read_text()
        for required in ['schemaVersion', 'CFBooleanGetTypeID', 'KDYZMOrigin', '[A-F0-9]{16}', 'multipleCodes']:
            self.assertIn(required, parser)
        for forbidden in ['URLSession', 'UserDefaults', 'print(', 'openURL']:
            self.assertNotIn(forbidden, parser)

    def test_explicit_origin_then_scope_confirmation(self):
        view = (ROOT / 'ParcelKeeper/Views/KDYZMSettingsView.swift').read_text()
        for required in ['扫描后台绑定二维码', '确认地址并预检', '确认授权并绑定', 'invalidatePreview', '.onChange(of: origin)', '.onChange(of: code)', 'Task.checkCancellation()', '同步后台快照']:
            self.assertIn(required, view)
        self.assertNotIn('同步京东快照', view)

if __name__ == '__main__':
    unittest.main()
