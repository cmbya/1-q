"""Source-level regression checks; XCTest behavior still requires Apple Swift/Xcode."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ROOT / "ParcelKeeper/Services"


class RefreshRepairContract(unittest.TestCase):
    def test_mall_failure_blocks_only_its_platform(self):
        text = (SERVICES / "TrackingRefreshService.swift").read_text()
        self.assertIn("error as? MallWebError, failure.stopsBatch", text)
        self.assertIn('blockedPlatforms.insert(platform)', text)

    def test_mall_generation_wraps_small_commit_not_network(self):
        text = (SERVICES / "TrackingRefreshService.swift").read_text()
        self.assertIn("MallSession.generation(for:", text)
        self.assertIn("MallSession.withGeneration(platform:", text)
        self.assertIn("let delivered = try commitResult {", text)
        self.assertIn("try? commitResult {", text)
        self.assertNotIn("await MallSession.withGeneration", text)

    def test_uapi_token_is_secret_free_and_atomic(self):
        text = (SERVICES / "UAPITrackingClient.swift").read_text()
        token = text.split("struct UAPIConfiguration", 1)[1].split("final class UAPISettingsService", 1)[0]
        self.assertNotIn("let key:", token)
        self.assertIn("func withConfiguration<T>", text)
        self.assertIn("Self.lock.lock(); defer { Self.lock.unlock() }", text)
        service = (SERVICES / "TrackingRefreshService.swift").read_text()
        self.assertIn("uapiConfiguration = try client.configurationToken()", service)
        self.assertIn("client.withConfiguration(uapiConfiguration, operation: operation)", service)
        self.assertIn("$0.requestStartedAt <= requestStartedAt", text)

    def test_default_uapi_transport_bounds_stream_before_buffering(self):
        text = (SERVICES / "UAPIBoundedNetwork.swift").read_text()
        self.assertIn("session.bytes(for: request)", text)
        self.assertIn("expectedContentLength", text)
        self.assertIn("body.count < Self.maximumResponseBytes", text)
        self.assertIn("bytes.task.cancel()", text)
        self.assertIn("configuration.httpCookieStorage = nil", text)
        self.assertIn("configuration.httpShouldSetCookies = false", text)
        self.assertIn("configuration.urlCache = nil", text)
        self.assertIn("completionHandler(nil)", text)
        client = (SERVICES / "UAPITrackingClient.swift").read_text()
        self.assertIn("network: any AINetworking = UAPIBoundedNetwork()", client)
        self.assertIn("request.httpShouldHandleCookies = false", client)

    def test_cross_source_history_is_flat_and_deduplicated(self):
        merger = (SERVICES / "KDYZMSync.swift").read_text()
        refresh = (SERVICES / "TrackingRefreshService.swift").read_text()
        self.assertIn("enum TrackingQueryHistory", merger)
        self.assertIn("TrackingQueryHistory.merged", refresh)
        self.assertIn("TrackingQueryHistory.merged", merger)
        self.assertNotIn("if local.backendEvents == nil { local.backendPreviousHistory = local.queryInfo }", merger)
        self.assertIn("Set<String>()", merger)

    def test_report_describes_attempts_not_billing_or_network_counts(self):
        text = (SERVICES / "TrackingRefreshService.swift").read_text()
        self.assertIn("按渠道尝试票数", text)
        self.assertIn("不代表实际网络请求或收费次数", text)

    def test_legacy_kdyzm_older_assertion_updated(self):
        text = (ROOT / "ParcelKeeperTests/KDYZMNetworkTests.swift").read_text()
        self.assertIn("testFailedEmptyPreserveButOlderLogisticsIsApplied", text)
        self.assertIn("XCTAssertEqual(local.logisticsTime, Date(timeIntervalSince1970: 100))", text)


if __name__ == "__main__":
    unittest.main()

