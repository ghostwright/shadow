import XCTest
@testable import Shadow

final class LearningRecorderTests: XCTestCase {

    // MARK: - Recording Lifecycle

    /// Recording starts and stops cleanly.
    func testStartStopRecording() async {
        let recorder = LearningRecorder()

        var isRecording = await recorder.isRecording
        XCTAssertFalse(isRecording)

        await recorder.startRecording()
        isRecording = await recorder.isRecording
        XCTAssertTrue(isRecording)

        let actions = await recorder.stopRecording()
        isRecording = await recorder.isRecording
        XCTAssertFalse(isRecording)
        XCTAssertTrue(actions.isEmpty, "No events recorded, so actions should be empty")
    }

    /// Double-start is idempotent.
    func testDoubleStartIsIdempotent() async {
        let recorder = LearningRecorder()
        await recorder.startRecording()
        await recorder.startRecording()  // Should not reset state
        let isRecording = await recorder.isRecording
        XCTAssertTrue(isRecording)
        _ = await recorder.stopRecording()
    }

    /// Stop when not recording returns empty.
    func testStopWhenNotRecording() async {
        let recorder = LearningRecorder()
        let actions = await recorder.stopRecording()
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Click Recording

    /// Click events are recorded.
    func testRecordClick() async {
        let recorder = LearningRecorder()
        await recorder.startRecording()

        await recorder.recordClick(x: 100, y: 200, button: "left", clickCount: 1, timestamp: 1000)

        let count = await recorder.actionCount
        XCTAssertEqual(count, 1)

        let actions = await recorder.stopRecording()
        XCTAssertEqual(actions.count, 1)

        if case .click(let x, let y, let button, let clickCount) = actions[0].actionType {
            XCTAssertEqual(x, 100)
            XCTAssertEqual(y, 200)
            XCTAssertEqual(button, "left")
            XCTAssertEqual(clickCount, 1)
        } else {
            XCTFail("Expected click action")
        }
    }

    /// Click events are not recorded when not in recording mode.
    func testClickIgnoredWhenNotRecording() async {
        let recorder = LearningRecorder()
        await recorder.recordClick(x: 100, y: 200, button: "left", clickCount: 1, timestamp: 1000)
        let count = await recorder.actionCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - Keystroke Recording

    /// Non-character keys are recorded as keyPress actions.
    func testRecordNonCharacterKey() async {
        let recorder = LearningRecorder()
        await recorder.startRecording()

        await recorder.recordKeystroke(
            chars: nil, keyCode: 36, keyName: "return",
            modifiers: [], isCharacterKey: false, timestamp: 2000
        )

        let actions = await recorder.stopRecording()
        XCTAssertEqual(actions.count, 1)

        if case .keyPress(let keyCode, let keyName, let modifiers) = actions[0].actionType {
            XCTAssertEqual(keyCode, 36)
            XCTAssertEqual(keyName, "return")
            XCTAssertTrue(modifiers.isEmpty)
        } else {
            XCTFail("Expected keyPress action")
        }
    }

    /// Character keystrokes are coalesced into typeText actions.
    func testKeystrokeCoalescing() async {
        let recorder = LearningRecorder()
        await recorder.startRecording()

        // Type "Hi" character by character
        await recorder.recordKeystroke(
            chars: "H", keyCode: 4, keyName: "h",
            modifiers: [], isCharacterKey: true, timestamp: 3000
        )
        await recorder.recordKeystroke(
            chars: "i", keyCode: 34, keyName: "i",
            modifiers: [], isCharacterKey: true, timestamp: 3100
        )

        // Force flush by recording a non-character key
        await recorder.recordKeystroke(
            chars: nil, keyCode: 36, keyName: "return",
            modifiers: [], isCharacterKey: false, timestamp: 4000
        )

        let actions = await recorder.stopRecording()
        // Should be 2 actions: typeText("Hi") + keyPress(return)
        XCTAssertEqual(actions.count, 2)

        if case .typeText(let text) = actions[0].actionType {
            XCTAssertEqual(text, "Hi")
        } else {
            XCTFail("Expected typeText action, got \(actions[0].actionType)")
        }

        if case .keyPress(_, let keyName, _) = actions[1].actionType {
            XCTAssertEqual(keyName, "return")
        } else {
            XCTFail("Expected keyPress action")
        }
    }

    // MARK: - App Switch Recording

    /// App switches are recorded.
    func testRecordAppSwitch() async {
        let recorder = LearningRecorder()
        await recorder.startRecording()

        await recorder.recordAppSwitch(
            toApp: "Safari", toBundleId: "com.apple.Safari", timestamp: 5000
        )

        let actions = await recorder.stopRecording()
        XCTAssertEqual(actions.count, 1)

        if case .appSwitch(let toApp, let toBundleId) = actions[0].actionType {
            XCTAssertEqual(toApp, "Safari")
            XCTAssertEqual(toBundleId, "com.apple.Safari")
        } else {
            XCTFail("Expected appSwitch action")
        }
    }

    // MARK: - Scroll Recording

    /// Scroll events are recorded.
    func testRecordScroll() async {
        let recorder = LearningRecorder()
        await recorder.startRecording()

        await recorder.recordScroll(deltaX: 0, deltaY: -3, x: 400, y: 300, timestamp: 6000)

        let actions = await recorder.stopRecording()
        XCTAssertEqual(actions.count, 1)

        if case .scroll(let dx, let dy, let x, let y) = actions[0].actionType {
            XCTAssertEqual(dx, 0)
            XCTAssertEqual(dy, -3)
            XCTAssertEqual(x, 400)
            XCTAssertEqual(y, 300)
        } else {
            XCTFail("Expected scroll action")
        }
    }

    // MARK: - Keystroke Flush on Stop

    /// Pending keystrokes are flushed when recording stops.
    func testKeystrokeFlushOnStop() async {
        let recorder = LearningRecorder()
        await recorder.startRecording()

        await recorder.recordKeystroke(
            chars: "a", keyCode: 0, keyName: "a",
            modifiers: [], isCharacterKey: true, timestamp: 7000
        )
        await recorder.recordKeystroke(
            chars: "b", keyCode: 11, keyName: "b",
            modifiers: [], isCharacterKey: true, timestamp: 7100
        )

        // Stop without sending a non-character key
        let actions = await recorder.stopRecording()
        XCTAssertEqual(actions.count, 1)

        if case .typeText(let text) = actions[0].actionType {
            XCTAssertEqual(text, "ab")
        } else {
            XCTFail("Expected typeText action")
        }
    }

    // MARK: - Recording State Callback

    /// Callback is invoked on start and stop.
    func testRecordingStateCallback() async {
        let recorder = LearningRecorder()

        // Use an actor to safely collect callback states
        let collector = StateCollector()

        await recorder.setOnRecordingStateChanged { state in
            Task { await collector.append(state) }
        }

        await recorder.startRecording()
        _ = await recorder.stopRecording()

        // Small delay for the callback Tasks to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        let states = await collector.states
        XCTAssertEqual(states, [true, false])
    }

    /// Multiple action types in sequence.
    func testMixedActionSequence() async {
        let recorder = LearningRecorder()
        await recorder.startRecording()

        // Click
        await recorder.recordClick(x: 50, y: 50, button: "left", clickCount: 1, timestamp: 1000)
        // Type
        await recorder.recordKeystroke(chars: "x", keyCode: 7, keyName: "x", modifiers: [], isCharacterKey: true, timestamp: 2000)
        // Click (flushes keystrokes)
        await recorder.recordClick(x: 200, y: 100, button: "left", clickCount: 1, timestamp: 3000)

        let actions = await recorder.stopRecording()
        // Expected: click, typeText("x"), click
        XCTAssertEqual(actions.count, 3)
    }
}

// Helper to set the callback from async context
extension LearningRecorder {
    func setOnRecordingStateChanged(_ callback: @escaping @Sendable (Bool) -> Void) {
        self.onRecordingStateChanged = callback
    }
}

/// Thread-safe collector for callback state values.
private actor StateCollector {
    var states: [Bool] = []

    func append(_ value: Bool) {
        states.append(value)
    }
}
