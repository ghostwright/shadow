import Foundation

/// Errors from Shadow's AX engine operations.
enum AXEngineError: Error, LocalizedError {
    case eventCreationFailed
    case actionFailed(action: String, axError: Int32)
    case elementHasNoFrame
    case elementNotFound(description: String)
    case elementNotActionable(String)
    case invalidHotkey(String)
    case verificationFailed(expected: String, actual: String)
    case replayVerificationFailed(step: Int, expected: String, actual: String)
    case timeout(seconds: Double)
    case lowConfidenceMatch(confidence: Double, threshold: Double)
    case captureSkipped(reason: String)

    var errorDescription: String? {
        switch self {
        case .eventCreationFailed: "Failed to create CGEvent"
        case .actionFailed(let a, let e): "AX action '\(a)' failed (error \(e))"
        case .elementHasNoFrame: "Element has no frame attribute"
        case .elementNotFound(let d): "Element not found: \(d)"
        case .elementNotActionable(let d): "Element is not actionable: \(d)"
        case .invalidHotkey(let k): "Invalid hotkey: \(k)"
        case .verificationFailed(let e, let a):
            "Verification failed: expected '\(e)', got '\(a)'"
        case .replayVerificationFailed(let s, let e, let a):
            "Step \(s) verification failed: expected '\(e)', got '\(a)'"
        case .timeout(let s): "Operation timed out after \(s)s"
        case .lowConfidenceMatch(let c, let t):
            "Match confidence \(String(format: "%.2f", c)) below threshold \(String(format: "%.2f", t))"
        case .captureSkipped(let r): "AX capture skipped: \(r)"
        }
    }
}
