import XCTest
@testable import Shadow

final class AXEngineErrorTests: XCTestCase {

    /// Every error case produces a non-empty description.
    func testAllErrorDescriptions() {
        let cases: [AXEngineError] = [
            .eventCreationFailed,
            .actionFailed(action: "AXPress", axError: -25204),
            .elementHasNoFrame,
            .elementNotFound(description: "AXButton 'OK'"),
            .elementNotActionable("No frame or actions"),
            .invalidHotkey("cmd+xyz"),
            .verificationFailed(expected: "hello", actual: "world"),
            .replayVerificationFailed(step: 3, expected: "signed in", actual: "error page"),
            .timeout(seconds: 5.0),
            .lowConfidenceMatch(confidence: 0.3, threshold: 0.5),
            .captureSkipped(reason: "tree unchanged"),
        ]

        for err in cases {
            let desc = err.errorDescription
            XCTAssertNotNil(desc, "errorDescription should not be nil for \(err)")
            XCTAssertFalse(desc!.isEmpty, "errorDescription should not be empty for \(err)")
        }
    }

    /// actionFailed includes the action name and error code.
    func testActionFailedDescription() {
        let err = AXEngineError.actionFailed(action: "AXPress", axError: -25204)
        let desc = err.errorDescription!
        XCTAssertTrue(desc.contains("AXPress"))
        XCTAssertTrue(desc.contains("-25204"))
    }

    /// verificationFailed includes expected and actual.
    func testVerificationFailedDescription() {
        let err = AXEngineError.verificationFailed(expected: "abc", actual: "xyz")
        let desc = err.errorDescription!
        XCTAssertTrue(desc.contains("abc"))
        XCTAssertTrue(desc.contains("xyz"))
    }

    /// replayVerificationFailed includes step number.
    func testReplayVerificationDescription() {
        let err = AXEngineError.replayVerificationFailed(step: 7, expected: "done", actual: "error")
        let desc = err.errorDescription!
        XCTAssertTrue(desc.contains("7"))
        XCTAssertTrue(desc.contains("done"))
        XCTAssertTrue(desc.contains("error"))
    }

    /// lowConfidenceMatch includes formatted numbers.
    func testLowConfidenceMatchDescription() {
        let err = AXEngineError.lowConfidenceMatch(confidence: 0.35, threshold: 0.50)
        let desc = err.errorDescription!
        XCTAssertTrue(desc.contains("0.35"))
        XCTAssertTrue(desc.contains("0.50"))
    }

    /// timeout includes the seconds.
    func testTimeoutDescription() {
        let err = AXEngineError.timeout(seconds: 15.0)
        let desc = err.errorDescription!
        XCTAssertTrue(desc.contains("15"))
    }

    /// AXEngineError conforms to Error protocol.
    func testConformsToError() {
        let err: Error = AXEngineError.eventCreationFailed
        XCTAssertNotNil(err.localizedDescription)
    }

    /// AXEngineError conforms to LocalizedError.
    func testConformsToLocalizedError() {
        let err: LocalizedError = AXEngineError.elementNotFound(description: "test")
        XCTAssertNotNil(err.errorDescription)
    }
}
