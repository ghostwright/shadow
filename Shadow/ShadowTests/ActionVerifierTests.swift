import XCTest
@testable import Shadow

final class ActionVerifierTests: XCTestCase {

    // MARK: - Tree Changed Verification

    /// Different hashes indicate tree changed.
    func testVerifyTreeChanged() {
        let result = ActionVerifier.verifyTreeChanged(preHash: 12345, postHash: 67890)
        XCTAssertTrue(result.passed)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.70)
        XCTAssertTrue(result.details.contains("changed"))
    }

    /// Same hashes indicate tree unchanged.
    func testVerifyTreeUnchanged() {
        let result = ActionVerifier.verifyTreeChanged(preHash: 12345, postHash: 12345)
        XCTAssertFalse(result.passed)
        XCTAssertLessThan(result.confidence, 0.50)
        XCTAssertTrue(result.details.contains("unchanged"))
    }

    // MARK: - VerificationResult Structure

    /// VerificationResult stores all fields.
    func testVerificationResultFields() {
        let result = ActionVerifier.VerificationResult(
            passed: true,
            confidence: 0.85,
            details: "test details"
        )
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.confidence, 0.85)
        XCTAssertEqual(result.details, "test details")
    }

    /// Failed verification with low confidence.
    func testFailedVerificationResult() {
        let result = ActionVerifier.VerificationResult(
            passed: false,
            confidence: 0.10,
            details: "mismatch detected"
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.confidence, 0.10)
    }

    // MARK: - Confidence Ranges

    /// Tree changed verification has reasonable confidence.
    func testTreeChangedConfidenceRange() {
        let changed = ActionVerifier.verifyTreeChanged(preHash: 1, postHash: 2)
        XCTAssertGreaterThan(changed.confidence, 0.0)
        XCTAssertLessThanOrEqual(changed.confidence, 1.0)

        let unchanged = ActionVerifier.verifyTreeChanged(preHash: 1, postHash: 1)
        XCTAssertGreaterThan(unchanged.confidence, 0.0)
        XCTAssertLessThanOrEqual(unchanged.confidence, 1.0)
    }
}
