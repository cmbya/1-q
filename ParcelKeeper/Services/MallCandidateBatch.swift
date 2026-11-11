// Legacy direct marketplace import is opt-in; source is retained for restoration.
#if ENABLE_DIRECT_MALL_IMPORT
import Foundation

struct MallCandidateBatchResult {
    var candidates: [MallCandidate] = []
    var attempted = 0
    var failed = 0
    var stopped: MallWebError?
    var message: String {
        var text = "逐单物流：尝试\(attempted)单，取得\(candidates.count)票真实运单，失败\(failed)单。"
        if let stopped { text += "后续已停止：" + (stopped.errorDescription ?? "平台会话不可用。") }
        return text
    }
}

/// A failed parcel must not erase successful previews. Never substitute an order ID.
@MainActor enum MallCandidateBatch {
    static func collect(orders: [MallWebOrder], detail: (MallWebOrder) async throws -> MallWebDetail) async throws -> MallCandidateBatchResult {
        var result = MallCandidateBatchResult()
        var ambiguous = Set<String>()
        // Eight useful previews, with a separate finite failure/attempt budget.
        for order in orders.prefix(24) {
            if result.candidates.count >= 8 { break }
            try Task.checkCancellation()
            result.attempted += 1
            do {
                let value = try await detail(order)
                guard !ambiguous.contains(value.number) else { result.failed += 1; continue }
                if let existing = result.candidates.first(where: { $0.trackingNumber == value.number }) {
                    if existing.orderID != order.id {
                        result.candidates.removeAll { $0.trackingNumber == value.number }
                        ambiguous.insert(value.number)
                        result.failed += 2
                    }
                } else {
                    result.candidates.append(MallCandidate(trackingNumber: value.number, carrier: value.carrier, title: order.title, orderID: order.id))
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.failed += 1
                if let failure = error as? MallWebError, failure.stopsBatch { result.stopped = failure; break }
            }
        }
        return result
    }
}
#endif
