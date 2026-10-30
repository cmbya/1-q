import Foundation

/// Select the recognition source once. AI errors propagate; local inference
/// never fills or replaces a successful AI result.
enum ShipmentRecognition {
    struct Result {
        var input: ShipmentShortcutInput
        let usesAI: Bool
    }
    static func recognize(_ text: String, useAI: Bool,
                          extractAI: (String) async throws -> ShipmentShortcutInput) async throws -> Result {
        try Task.checkCancellation()
        var input: ShipmentShortcutInput
        if useAI { input = try await extractAI(text) }
        else { input = try ShipmentShortcutParser.parse(text) }
        try Task.checkCancellation()
        // Preserve the exact received text, never a model-generated version.
        input.queryInfo = text
        return Result(input: input, usesAI: useAI)
    }
}
