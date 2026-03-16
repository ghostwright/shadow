import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ExecutionUndoManager")

// MARK: - Execution Undo Manager

/// Maintains an undo stack for procedure execution.
///
/// Each executed step is captured as an UndoSnapshot containing:
/// - The step index and action type
/// - The AX tree hash before execution
/// - The action that was performed
///
/// On undo, steps are popped LIFO. The manager attempts to reverse
/// each action: Cmd+Z for typing, re-click to toggle buttons, etc.
///
/// Actor isolation ensures thread-safe stack operations.
actor ExecutionUndoManager {

    private var undoStack: [UndoSnapshot] = []
    private var maxStackSize: Int

    init(maxStackSize: Int = 100) {
        self.maxStackSize = maxStackSize
    }

    // MARK: - Stack Operations

    /// Push an undo snapshot before executing a step.
    func push(_ snapshot: UndoSnapshot) {
        if undoStack.count >= maxStackSize {
            // Remove oldest entry to stay within budget
            undoStack.removeFirst()
        }
        undoStack.append(snapshot)
        let stackCount = undoStack.count
        logger.debug("Undo snapshot pushed for step \(snapshot.stepIndex) (\(stackCount) in stack)")
    }

    /// Pop the most recent undo snapshot.
    func pop() -> UndoSnapshot? {
        guard !undoStack.isEmpty else { return nil }
        let snapshot = undoStack.removeLast()
        let remaining = undoStack.count
        logger.debug("Undo snapshot popped for step \(snapshot.stepIndex) (\(remaining) remaining)")
        return snapshot
    }

    /// Peek at the top of the undo stack without removing.
    func peek() -> UndoSnapshot? {
        undoStack.last
    }

    /// Number of undo snapshots available.
    var count: Int { undoStack.count }

    /// Whether the undo stack is empty.
    var isEmpty: Bool { undoStack.isEmpty }

    /// Clear all undo snapshots (e.g., on execution completion).
    func clear() {
        let count = undoStack.count
        undoStack.removeAll()
        logger.info("Undo stack cleared (\(count) snapshots)")
    }

    /// All step indices in the undo stack (for UI display).
    var stepIndices: [Int] {
        undoStack.map(\.stepIndex)
    }

    // MARK: - Undo Execution

    /// Attempt to undo the most recent step by reversing its action.
    ///
    /// Returns the reversal strategy that was applied, or nil if no undo was possible.
    /// The caller is responsible for executing the actual reversal action.
    func computeReversal() -> (snapshot: UndoSnapshot, strategy: UndoStrategy)? {
        guard let snapshot = undoStack.last else { return nil }

        let strategy: UndoStrategy
        switch snapshot.actionType {
        case .typeText:
            // Reverse text entry with Cmd+Z
            strategy = .undoShortcut

        case .click(_, _, _, let count) where count == 1:
            // Single clicks on toggles can be reversed by clicking again
            // For other clicks, Cmd+Z is the safest reversal
            strategy = .undoShortcut

        case .keyPress(_, let keyName, let modifiers):
            // If this was already Cmd+Z, we need Cmd+Shift+Z (redo) to reverse
            if keyName == "z" && modifiers.contains("cmd") && !modifiers.contains("shift") {
                strategy = .redoShortcut
            } else {
                strategy = .undoShortcut
            }

        case .appSwitch(let toApp, _):
            // App switch can be reversed by switching back
            strategy = .switchBack(fromApp: toApp)

        case .scroll(let deltaX, let deltaY, let x, let y):
            // Reverse scroll direction
            strategy = .reverseScroll(deltaX: -deltaX, deltaY: -deltaY, x: x, y: y)

        case .click:
            strategy = .undoShortcut
        }

        return (snapshot, strategy)
    }

    /// Pop and return the reversal for the most recent step.
    func popReversal() -> (snapshot: UndoSnapshot, strategy: UndoStrategy)? {
        guard let result = computeReversal() else { return nil }
        _ = pop()
        return result
    }
}

// MARK: - Undo Types

/// Snapshot of state before a procedure step executed.
struct UndoSnapshot: Sendable {
    let stepIndex: Int
    let actionType: RecordedAction.ActionType
    let preTreeHash: UInt64
    let timestamp: UInt64  // When the snapshot was taken
}

/// Strategy for reversing an executed step.
enum UndoStrategy: Sendable {
    /// Send Cmd+Z to undo the action.
    case undoShortcut
    /// Send Cmd+Shift+Z to redo (reverse of undo).
    case redoShortcut
    /// Switch back to the previous app.
    case switchBack(fromApp: String)
    /// Reverse scroll in the opposite direction.
    case reverseScroll(deltaX: Int, deltaY: Int, x: Double, y: Double)
    /// No automated reversal possible — requires user intervention.
    case manual(reason: String)
}
