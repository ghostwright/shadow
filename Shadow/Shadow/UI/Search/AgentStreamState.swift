import Foundation

/// Status of the agent run from the UI's perspective.
enum AgentStatus: Equatable {
    case starting
    case streaming
    case toolRunning
    case complete
}

/// Status of a single tool call in the timeline.
enum ToolActivityStatus: Equatable {
    case running
    case completed(durationMs: Double)
    case failed(error: String)
}

/// A single entry in the tool activity timeline.
struct ToolActivityEntry: Equatable, Identifiable {
    let id = UUID()
    let name: String
    let step: Int
    var status: ToolActivityStatus

    static func == (lhs: ToolActivityEntry, rhs: ToolActivityEntry) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.step == rhs.step && lhs.status == rhs.status
    }
}

/// Mutable state accumulator for an in-flight agent run.
/// Mutated exclusively on MainActor by the reducer in SearchViewModel.
struct AgentStreamState: Equatable {
    var task: String = ""
    var liveAnswer: String = ""
    var toolTimeline: [ToolActivityEntry] = []
    var evidence: [AgentEvidenceItem] = []
    var metrics: AgentRunMetrics?
    var status: AgentStatus = .starting
    var currentStep: Int = 0

    /// Orchestration metadata — shown in the UI header.
    var classifiedIntent: String?
    var classifiedConfidence: Double?
    var classificationMethod: String?
}

// MARK: - AgentRunError Display

extension AgentRunError {
    /// User-facing error description for display in the command error view.
    var displayMessage: String {
        switch self {
        case .budgetExhausted(let steps, let toolCalls):
            "The agent reached its processing limit (\(steps) steps, \(toolCalls) tool calls) without a final answer."
        case .timeout(let elapsedSeconds):
            "The agent timed out after \(Int(elapsedSeconds)) seconds."
        case .providerError(let detail):
            detail
        case .noToolsAvailable:
            "No tools are available for the agent. Check Diagnostics for details."
        case .cancelled:
            "The agent run was cancelled."
        case .internalError(let detail):
            "Internal error: \(detail)"
        }
    }
}
