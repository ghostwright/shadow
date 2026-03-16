import Foundation

/// A structured execution plan produced by the CloudPlanner.
///
/// The plan decomposes a user's task into concrete UI action steps that
/// the LocalExecutor can follow autonomously. Each step describes WHAT to do,
/// WHERE to do it, and HOW to verify it worked.
///
/// The cloud planner generates this ONCE. The local executor handles everything
/// locally, calling back to the planner only on failures or unexpected states.
///
/// Mimicry Phase C: Two-Tier Planning Protocol.
struct TaskPlan: Codable, Sendable {
    /// Unique identifier for this plan.
    let id: String

    /// The original user request (e.g., "Send an email to John about meeting notes").
    let taskDescription: String

    /// Ordered list of execution steps.
    let steps: [PlanStep]

    /// How to know the task is done (e.g., "Email sent confirmation visible").
    let successCriteria: String

    /// What to do if a step fails (e.g., "Check if Gmail is loaded, retry compose").
    let recoveryHint: String

    /// The app context this plan was generated for.
    let targetApp: String?

    /// Timestamp when the plan was generated.
    let createdAt: Date

    /// Whether the plan has been validated against the current AX tree state.
    var isValidated: Bool = false

    init(
        id: String = UUID().uuidString,
        taskDescription: String,
        steps: [PlanStep],
        successCriteria: String,
        recoveryHint: String = "",
        targetApp: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskDescription = taskDescription
        self.steps = steps
        self.successCriteria = successCriteria
        self.recoveryHint = recoveryHint
        self.targetApp = targetApp
        self.createdAt = createdAt
    }

    /// Total number of steps in the plan.
    var stepCount: Int { steps.count }
}

/// A single concrete action step within a TaskPlan.
///
/// Each step describes a UI interaction that the LocalExecutor will perform.
/// Steps are designed to be self-contained: the executor can attempt each one
/// independently using AX tree search or VLM grounding.
struct PlanStep: Codable, Sendable, Identifiable {
    /// Step index (0-based).
    let index: Int

    /// Human-readable description (e.g., "Click the Compose button in Gmail").
    let description: String

    /// The action to perform.
    let actionType: PlanActionType

    /// Description of the target element (e.g., "AXButton titled 'Compose'").
    /// Used by the grounding system to find the element.
    let targetDescription: String?

    /// Text to type (for `.type` actions).
    let inputText: String?

    /// Key names (for `.hotkey` actions, e.g., ["cmd", "return"]).
    let keys: [String]?

    /// Condition to verify after action (e.g., "elementExists: 'To recipients'").
    let waitCondition: String?

    /// AX role hint for faster element search (e.g., "AXButton").
    let roleHint: String?

    /// Maximum seconds to wait for the waitCondition (default: 5).
    let waitTimeoutSeconds: Double?

    /// Identifiable conformance.
    var id: Int { index }
}

/// Types of actions the executor can perform.
enum PlanActionType: String, Codable, Sendable {
    /// Click a UI element.
    case click
    /// Type text into a field.
    case type
    /// Press a keyboard shortcut.
    case hotkey
    /// Navigate to a URL or location.
    case navigate
    /// Wait for a condition to be met.
    case wait
    /// Focus an application.
    case focusApp
    /// Scroll in a direction.
    case scroll
    /// Press a single key (Tab, Return, Escape).
    case keyPress
}

// MARK: - Execution State

/// Tracks the execution state of a plan.
struct PlanExecutionState: Sendable {
    /// The plan being executed.
    let plan: TaskPlan

    /// Index of the current step being executed (or next to execute).
    var currentStepIndex: Int = 0

    /// Results for each step that has been attempted.
    var stepResults: [StepResult] = []

    /// Overall execution status.
    var status: PlanExecutionStatus = .pending

    /// Whether execution has completed (success or failure).
    var isComplete: Bool {
        switch status {
        case .succeeded, .failed, .cancelled:
            return true
        case .pending, .executing, .escalated:
            return false
        }
    }

    /// Number of steps completed successfully.
    var completedSteps: Int {
        stepResults.filter { $0.status == .succeeded }.count
    }

    /// Number of steps that failed.
    var failedSteps: Int {
        stepResults.filter { $0.status == .failed }.count
    }
}

/// Result of executing a single plan step.
struct StepResult: Sendable {
    /// Step index.
    let stepIndex: Int

    /// Execution status.
    let status: StepExecutionStatus

    /// Description of what happened.
    let message: String

    /// How long the step took to execute (milliseconds).
    let durationMs: Double

    /// Which grounding strategy found the element (if applicable).
    let groundingStrategy: GroundingStrategy?

    /// Number of retry attempts for this step.
    let retryCount: Int
}

/// Status of a single step execution.
enum StepExecutionStatus: String, Sendable {
    case succeeded
    case failed
    case skipped
    case escalated
}

/// Status of the overall plan execution.
enum PlanExecutionStatus: String, Sendable {
    case pending
    case executing
    case succeeded
    case failed
    case cancelled
    /// Plan has been escalated back to the cloud planner.
    case escalated
}

// MARK: - Escalation

/// A request to the cloud planner for help with a failed step.
struct EscalationRequest: Codable, Sendable {
    /// The original plan.
    let plan: TaskPlan

    /// The step that failed.
    let failedStepIndex: Int

    /// What went wrong.
    let failureReason: String

    /// Current AX tree summary at the time of failure.
    let currentAXState: String?

    /// How many times the step has been retried.
    let retryCount: Int
}

/// The planner's response to an escalation.
struct EscalationResponse: Codable, Sendable {
    /// Whether the planner could resolve the issue.
    let resolved: Bool

    /// Revised steps to replace the failed step (and optionally subsequent steps).
    let revisedSteps: [PlanStep]?

    /// Advice for the executor.
    let advice: String?

    /// Whether to abort the entire plan.
    let shouldAbort: Bool
}
