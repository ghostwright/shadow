import XCTest
@testable import Shadow

final class ExecutionUndoManagerTests: XCTestCase {

    // MARK: - Stack Operations

    /// Push and pop a single snapshot.
    func testPushAndPop() async {
        let manager = ExecutionUndoManager()
        let snapshot = makeSnapshot(stepIndex: 0, actionType: .click(x: 100, y: 200, button: "left", count: 1))

        await manager.push(snapshot)
        let count = await manager.count
        XCTAssertEqual(count, 1)

        let popped = await manager.pop()
        XCTAssertNotNil(popped)
        XCTAssertEqual(popped?.stepIndex, 0)

        let afterCount = await manager.count
        XCTAssertEqual(afterCount, 0)
    }

    /// Pop from empty stack returns nil.
    func testPopEmptyStack() async {
        let manager = ExecutionUndoManager()
        let popped = await manager.pop()
        XCTAssertNil(popped)
    }

    /// Push multiple snapshots and pop in LIFO order.
    func testLIFOOrder() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(stepIndex: 0, actionType: .click(x: 1, y: 1, button: "left", count: 1)))
        await manager.push(makeSnapshot(stepIndex: 1, actionType: .typeText(text: "hi")))
        await manager.push(makeSnapshot(stepIndex: 2, actionType: .keyPress(keyCode: 36, keyName: "return", modifiers: [])))

        let count = await manager.count
        XCTAssertEqual(count, 3)

        let p1 = await manager.pop()
        XCTAssertEqual(p1?.stepIndex, 2)

        let p2 = await manager.pop()
        XCTAssertEqual(p2?.stepIndex, 1)

        let p3 = await manager.pop()
        XCTAssertEqual(p3?.stepIndex, 0)
    }

    /// Peek returns top without removing.
    func testPeek() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(stepIndex: 5, actionType: .click(x: 0, y: 0, button: "left", count: 1)))

        let peeked = await manager.peek()
        XCTAssertNotNil(peeked)
        XCTAssertEqual(peeked?.stepIndex, 5)

        let count = await manager.count
        XCTAssertEqual(count, 1, "Peek should not remove the item")
    }

    /// Peek on empty stack returns nil.
    func testPeekEmpty() async {
        let manager = ExecutionUndoManager()
        let peeked = await manager.peek()
        XCTAssertNil(peeked)
    }

    /// Clear removes all snapshots.
    func testClear() async {
        let manager = ExecutionUndoManager()
        for i in 0..<5 {
            await manager.push(makeSnapshot(stepIndex: i, actionType: .click(x: 0, y: 0, button: "left", count: 1)))
        }
        let preClear = await manager.count
        XCTAssertEqual(preClear, 5)

        await manager.clear()

        let postClear = await manager.count
        XCTAssertEqual(postClear, 0)
        let isEmpty = await manager.isEmpty
        XCTAssertTrue(isEmpty)
    }

    /// Max stack size is enforced by removing oldest entries.
    func testMaxStackSize() async {
        let manager = ExecutionUndoManager(maxStackSize: 3)

        await manager.push(makeSnapshot(stepIndex: 0, actionType: .click(x: 0, y: 0, button: "left", count: 1)))
        await manager.push(makeSnapshot(stepIndex: 1, actionType: .click(x: 0, y: 0, button: "left", count: 1)))
        await manager.push(makeSnapshot(stepIndex: 2, actionType: .click(x: 0, y: 0, button: "left", count: 1)))
        await manager.push(makeSnapshot(stepIndex: 3, actionType: .click(x: 0, y: 0, button: "left", count: 1)))

        let count = await manager.count
        XCTAssertEqual(count, 3, "Stack should not exceed max size")

        // Oldest (step 0) should have been evicted
        let indices = await manager.stepIndices
        XCTAssertFalse(indices.contains(0), "Step 0 should have been evicted")
        XCTAssertTrue(indices.contains(3), "Step 3 should be present")
    }

    /// stepIndices returns all indices in order.
    func testStepIndices() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(stepIndex: 0, actionType: .click(x: 0, y: 0, button: "left", count: 1)))
        await manager.push(makeSnapshot(stepIndex: 1, actionType: .typeText(text: "x")))
        await manager.push(makeSnapshot(stepIndex: 2, actionType: .scroll(deltaX: 0, deltaY: -3, x: 400, y: 300)))

        let indices = await manager.stepIndices
        XCTAssertEqual(indices, [0, 1, 2])
    }

    // MARK: - Undo Strategy Computation

    /// Text entry produces undo shortcut strategy.
    func testTextEntryUndoStrategy() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(stepIndex: 0, actionType: .typeText(text: "hello")))

        let reversal = await manager.computeReversal()
        XCTAssertNotNil(reversal)
        if case .undoShortcut = reversal!.strategy {
            // correct
        } else {
            XCTFail("Expected undoShortcut for typeText")
        }
    }

    /// Click produces undo shortcut strategy.
    func testClickUndoStrategy() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(stepIndex: 0, actionType: .click(x: 100, y: 200, button: "left", count: 1)))

        let reversal = await manager.computeReversal()
        XCTAssertNotNil(reversal)
        if case .undoShortcut = reversal!.strategy {
            // correct
        } else {
            XCTFail("Expected undoShortcut for click")
        }
    }

    /// Scroll produces reverse scroll strategy.
    func testScrollUndoStrategy() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(
            stepIndex: 0,
            actionType: .scroll(deltaX: 0, deltaY: -3, x: 400, y: 300)
        ))

        let reversal = await manager.computeReversal()
        XCTAssertNotNil(reversal)
        if case .reverseScroll(let dx, let dy, let x, let y) = reversal!.strategy {
            XCTAssertEqual(dx, 0)
            XCTAssertEqual(dy, 3, "Reversed deltaY should be positive")
            XCTAssertEqual(x, 400)
            XCTAssertEqual(y, 300)
        } else {
            XCTFail("Expected reverseScroll for scroll")
        }
    }

    /// App switch produces switch back strategy.
    func testAppSwitchUndoStrategy() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(
            stepIndex: 0,
            actionType: .appSwitch(toApp: "Safari", toBundleId: "com.apple.Safari")
        ))

        let reversal = await manager.computeReversal()
        XCTAssertNotNil(reversal)
        if case .switchBack(let fromApp) = reversal!.strategy {
            XCTAssertEqual(fromApp, "Safari")
        } else {
            XCTFail("Expected switchBack for appSwitch")
        }
    }

    /// Cmd+Z keypress produces redo shortcut strategy (reversal of undo is redo).
    func testCmdZUndoStrategyIsRedo() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(
            stepIndex: 0,
            actionType: .keyPress(keyCode: 6, keyName: "z", modifiers: ["cmd"])
        ))

        let reversal = await manager.computeReversal()
        XCTAssertNotNil(reversal)
        if case .redoShortcut = reversal!.strategy {
            // correct — reversing Cmd+Z is Cmd+Shift+Z
        } else {
            XCTFail("Expected redoShortcut for Cmd+Z reversal")
        }
    }

    /// computeReversal does not remove the snapshot.
    func testComputeReversalDoesNotPop() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(stepIndex: 0, actionType: .click(x: 0, y: 0, button: "left", count: 1)))

        _ = await manager.computeReversal()
        let count = await manager.count
        XCTAssertEqual(count, 1, "computeReversal should not remove the snapshot")
    }

    /// popReversal removes the snapshot.
    func testPopReversalRemovesSnapshot() async {
        let manager = ExecutionUndoManager()
        await manager.push(makeSnapshot(stepIndex: 0, actionType: .click(x: 0, y: 0, button: "left", count: 1)))

        let reversal = await manager.popReversal()
        XCTAssertNotNil(reversal)

        let count = await manager.count
        XCTAssertEqual(count, 0, "popReversal should remove the snapshot")
    }

    /// computeReversal on empty stack returns nil.
    func testComputeReversalEmpty() async {
        let manager = ExecutionUndoManager()
        let reversal = await manager.computeReversal()
        XCTAssertNil(reversal)
    }

    // MARK: - Helpers

    private func makeSnapshot(
        stepIndex: Int,
        actionType: RecordedAction.ActionType
    ) -> UndoSnapshot {
        UndoSnapshot(
            stepIndex: stepIndex,
            actionType: actionType,
            preTreeHash: UInt64(stepIndex * 1000),
            timestamp: CaptureSessionClock.wallMicros()
        )
    }
}
