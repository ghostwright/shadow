import Foundation

/// Bridges LLMOrchestrator (actor) to the LLMProvider protocol.
///
/// ProcedureSynthesizer expects an LLMProvider. This bridge wraps the orchestrator's
/// `generate()` method, allowing the synthesizer to use whatever provider the
/// orchestrator selects (local or cloud).
final class OrchestratorLLMBridge: LLMProvider, @unchecked Sendable {
    let providerName: String = "orchestrator_bridge"
    let modelId: String = "auto"

    private let orchestrator: LLMOrchestrator

    init(orchestrator: LLMOrchestrator) {
        self.orchestrator = orchestrator
    }

    var isAvailable: Bool {
        // Synchronous check — cannot call actor method synchronously.
        // Assume available; the actual generate call will throw if not.
        true
    }

    func generate(request: LLMRequest) async throws -> LLMResponse {
        try await orchestrator.generate(request: request)
    }
}
