"""Offline source contracts; these do NOT execute Swift, Keychain or concurrency."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def read(name): return (ROOT / name).read_text()
class JDReviewRepairs(unittest.TestCase):
    def test_shared_session_generation_is_locked_and_atomic(self):
        s = read('ParcelKeeper/Services/MallWebClient.swift')
        self.assertIn('private static let sessionLock = NSRecursiveLock()', s)
        self.assertIn('static func generation(for platform: MallPlatform) -> UUID', s)
        self.assertIn('static func withGeneration<T>(platform: MallPlatform, expected: UUID, operation: () throws -> T) throws -> T', s)
        self.assertIn('guard currentGeneration(for: platform) == expected else { throw CancellationError() }', s)
        self.assertIn('defer { Self.advanceGeneration(for: platform) }', s)
        self.assertIn('expectedGeneration: UUID? = nil', s)
        self.assertIn('func saveRotated(', s)
        self.assertIn('replacing original: [TaobaoTrialCookie]', s)
        rotation = s.split('func saveRotated(', 1)[1].split('func clear()', 1)[0]
        self.assertIn('Self.encoded(active) == Self.encoded(original)', rotation)
        self.assertIn('catch { Self.advanceGeneration(for: platform); throw MallWebError.authentication }', rotation)
        self.assertNotIn('defer { Self.advanceGeneration', rotation)
    def test_pc_verification_returns_rotated_snapshot_without_logging_it(self):
        s = read('ParcelKeeper/Services/JDPCClient.swift')
        self.assertIn('func verifySession() async throws -> [TaobaoTrialCookie]', s)
        self.assertIn('return session.cookies', s)
        self.assertIn('if stage != .jdVerify', s)
        self.assertIn('saveRotated(session.cookies, replacing: cookies, expectedGeneration: generation)', s)
        self.assertNotIn('print(', s)
    def test_import_and_preview_bind_to_session_generation(self):
        s = read('ParcelKeeper/Views/MallImportView.swift')
        self.assertIn('let fresh = try await MallImportClient(platform: currentPlatform, cookies: parsed).verifiedCookies()', s)
        self.assertIn('save(fresh, expectedGeneration: generation)', s)
        self.assertNotIn('session.save(parsed)', s)
        self.assertIn('candidateGeneration', s)
        self.assertIn('MallSession.withGeneration(platform: currentPlatform, expected: generation)', s)
        self.assertIn('MallSession.withGeneration(platform: browser.platform, expected: generation)', s)
        self.assertIn('MallSession.generation(for: currentPlatform) == generation', s)
    def test_jd_diagnostics_terminal_and_event_state_share_lock(self):
        s = read('ParcelKeeper/Services/JDDiagnostics.swift')
        self.assertIn('private let lock = NSLock()', s)
        self.assertGreaterEqual(s.count('lock.lock(); defer { lock.unlock() }'), 4)
        begin = s.split('func begin(', 1)[1].split('func event(', 1)[0]
        self.assertIn('guard !ended else { return }', begin)
    def test_query_checks_generation_after_network(self):
        s = read('ParcelKeeper/Services/MallWebClient.swift').split('struct MallTrackingClient:', 1)[1].split('enum MallWebError:', 1)[0]
        self.assertIn('let generation = MallSession.generation(for: platform)', s)
        self.assertGreaterEqual(s.count('MallSession.withGeneration(platform: platform, expected: generation)'), 2)
if __name__ == '__main__': unittest.main()
