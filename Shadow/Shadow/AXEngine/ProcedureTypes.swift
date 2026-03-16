import Foundation

// MARK: - Procedure Data Types

/// A recorded user action during learning mode.
/// Captures the action type, timing, AX context before/after, and the target element.
struct RecordedAction: Codable, Sendable {
    let timestamp: UInt64           // Unix microseconds
    let actionType: ActionType
    let appName: String
    let appBundleId: String
    let windowTitle: String?
    let targetLocator: ElementLocator?  // Locator for the element acted upon
    let targetDescription: String?      // Human-readable description
    let preTreeHash: UInt64?            // AX tree hash before the action
    let postTreeHash: UInt64?           // AX tree hash after the action
    let nodeCountBefore: Int?           // Node count before
    let nodeCountAfter: Int?            // Node count after

    /// Type of action performed.
    enum ActionType: Codable, Sendable {
        case click(x: Double, y: Double, button: String, count: Int)
        case typeText(text: String)
        case keyPress(keyCode: Int, keyName: String, modifiers: [String])
        case appSwitch(toApp: String, toBundleId: String)
        case scroll(deltaX: Int, deltaY: Int, x: Double, y: Double)
    }
}

/// A synthesized procedure template produced by the LLM from recorded actions.
/// This is what gets stored and replayed.
struct ProcedureTemplate: Codable, Sendable, Identifiable {
    let id: String                  // UUID
    var name: String                // LLM-generated name (2-5 words)
    var description: String         // LLM-generated description
    var parameters: [ProcedureParameter]
    var steps: [ProcedureStep]
    let createdAt: UInt64           // Unix microseconds
    var updatedAt: UInt64           // Unix microseconds
    let sourceApp: String           // Primary app the procedure was recorded in
    let sourceBundleId: String
    var tags: [String]              // LLM-generated tags for discovery
    var executionCount: Int         // How many times replayed successfully
    var lastExecutedAt: UInt64?     // Last successful execution timestamp
}

/// A parameter that can be substituted when replaying a procedure.
struct ProcedureParameter: Codable, Sendable {
    let name: String                // e.g., "recipient_email"
    let paramType: String           // "string", "number", "date", "email", "url"
    let description: String         // LLM-generated description
    let stepIndices: [Int]          // Which steps use this parameter (0-indexed)
    var defaultValue: String?       // Optional default from recording
}

/// A single step in a procedure template.
struct ProcedureStep: Codable, Sendable {
    let index: Int                  // 0-indexed step number
    let intent: String              // LLM-generated intent description
    let actionType: RecordedAction.ActionType
    let targetLocator: ElementLocator?
    let targetDescription: String?
    var parameterSubstitutions: [String: String]  // parameter name -> placeholder in action
    let expectedPostCondition: String?            // LLM-generated expected state after step
    let maxRetries: Int                           // How many times to retry on failure (default 2)
    let timeoutSeconds: Double                    // Max time to wait for element/state (default 5)
}

/// Status of a procedure execution run.
enum ProcedureExecutionStatus: String, Codable, Sendable {
    case running
    case paused
    case completed
    case failed
    case cancelled
}

/// Event emitted during procedure execution for the UI progress panel.
enum ExecutionEvent: Sendable {
    case stepStarting(index: Int, intent: String)
    case stepCompleted(index: Int, verified: Bool, confidence: Double)
    case stepFailed(index: Int, error: String)
    case stepRetrying(index: Int, attempt: Int, reason: String)
    case safetyGateTriggered(index: Int, classification: String, reason: String)
    case executionCompleted(totalSteps: Int, successfulSteps: Int)
    case executionFailed(atStep: Int, error: String)
    case executionCancelled(atStep: Int)
}

// Note: ProcedureRecord is defined by UniFFI in Generated/shadow_core.swift
// (from shadow-core/src/timeline.rs). It contains the SQLite-indexed metadata.
// Use the UniFFI-generated type directly for Rust interop.
