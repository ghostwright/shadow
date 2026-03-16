import XCTest
@testable import Shadow

final class PatternExtractorTests: XCTestCase {

    // MARK: - Eligibility Tests

    func testIsEligible_withEnoughAXCalls() {
        let result = makeResult(toolNames: [
            "ax_focus_app", "ax_tree_query", "ax_click",
            "ax_type", "ax_hotkey"
        ])
        XCTAssertTrue(PatternExtractor.isEligible(result))
    }

    func testIsEligible_withExactMinimum() {
        let result = makeResult(toolNames: [
            "ax_focus_app", "ax_tree_query", "ax_click"
        ])
        XCTAssertTrue(PatternExtractor.isEligible(result))
    }

    func testIsNotEligible_tooFewAXCalls() {
        let result = makeResult(toolNames: [
            "search_hybrid", "get_timeline_context", "ax_focus_app"
        ])
        XCTAssertFalse(PatternExtractor.isEligible(result))
    }

    func testIsNotEligible_noAXCalls() {
        let result = makeResult(toolNames: [
            "search_hybrid", "get_transcript_window", "get_day_summary"
        ])
        XCTAssertFalse(PatternExtractor.isEligible(result))
    }

    func testIsEligible_livescreenshotCountsAsAX() {
        let result = makeResult(toolNames: [
            "capture_live_screenshot", "ax_click", "ax_type"
        ])
        XCTAssertTrue(PatternExtractor.isEligible(result))
    }

    // MARK: - Heuristic Extraction Tests

    func testHeuristicExtraction_createsPattern() {
        let result = makeResult(toolNames: [
            "ax_focus_app", "ax_tree_query", "ax_click",
            "ax_type", "ax_tree_query"
        ])

        let pattern = PatternExtractor.extractHeuristic(task: "Add to cart", result: result)
        XCTAssertNotNil(pattern)
        XCTAssertEqual(pattern?.taskDescription, "Add to cart")
        XCTAssertEqual(pattern?.successCount, 1)
        XCTAssertEqual(pattern?.failureCount, 0)
        XCTAssertFalse(pattern?.archived ?? true)
    }

    func testHeuristicExtraction_compactsDuplicateQueries() {
        let result = makeResult(toolNames: [
            "ax_focus_app", "ax_tree_query", "ax_tree_query",
            "ax_tree_query", "ax_click"
        ])

        let pattern = PatternExtractor.extractHeuristic(task: "Click button", result: result)
        XCTAssertNotNil(pattern)

        // Consecutive ax_tree_query calls should be compacted
        let toolNames = pattern?.toolSequence.map(\.toolName) ?? []
        let consecutiveQueryCount = zip(toolNames, toolNames.dropFirst())
            .filter { $0.0 == "ax_tree_query" && $0.1 == "ax_tree_query" }
            .count
        XCTAssertEqual(consecutiveQueryCount, 0, "Consecutive ax_tree_query should be compacted")
    }

    func testHeuristicExtraction_capsStepCount() {
        // Create a result with many tool calls
        let toolNames = (0..<30).map { _ in "ax_tree_query" }
        let result = makeResult(toolNames: toolNames)

        let pattern = PatternExtractor.extractHeuristic(task: "Long task", result: result)
        XCTAssertNotNil(pattern)
        XCTAssertLessThanOrEqual(pattern?.toolSequence.count ?? 0, 15)
    }

    func testHeuristicExtraction_returnsNilWhenNotEligible() {
        let result = makeResult(toolNames: ["search_hybrid"])
        let pattern = PatternExtractor.extractHeuristic(task: "Search", result: result)
        XCTAssertNil(pattern)
    }

    // MARK: - Helpers

    private func makeResult(toolNames: [String]) -> AgentRunResult {
        let records = toolNames.map { name in
            AgentToolCallRecord(
                toolName: name,
                arguments: name == "ax_focus_app" ? ["app": .string("Chrome")] : [:],
                output: "ok",
                durationMs: 50,
                success: true
            )
        }
        return AgentRunResult(
            answer: "Done",
            evidence: [],
            toolCalls: records,
            metrics: AgentRunMetrics(
                totalMs: 2000,
                stepCount: 3,
                toolCallCount: toolNames.count,
                inputTokensTotal: 500,
                outputTokensTotal: 200,
                provider: "test",
                modelId: "test-model"
            )
        )
    }
}
