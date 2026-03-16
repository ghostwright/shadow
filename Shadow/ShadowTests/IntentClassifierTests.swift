import XCTest
@testable import Shadow

final class IntentClassifierTests: XCTestCase {

    // MARK: - UserIntent Type

    /// All intent cases exist.
    func testAllIntentCases() {
        let cases = IntentClassifier.UserIntent.allCases
        XCTAssertEqual(cases.count, 8)
        XCTAssertTrue(cases.contains(.simpleQuestion))
        XCTAssertTrue(cases.contains(.memorySearch))
        XCTAssertTrue(cases.contains(.procedureReplay))
        XCTAssertTrue(cases.contains(.procedureLearning))
        XCTAssertTrue(cases.contains(.complexReasoning))
        XCTAssertTrue(cases.contains(.directiveCreation))
        XCTAssertTrue(cases.contains(.uiAction))
        XCTAssertTrue(cases.contains(.ambiguous))
    }

    /// UserIntent is Codable.
    func testIntentCodable() throws {
        let intent = IntentClassifier.UserIntent.memorySearch
        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(IntentClassifier.UserIntent.self, from: data)
        XCTAssertEqual(intent, decoded)
    }

    /// UserIntent raw values are camelCase.
    func testIntentRawValues() {
        XCTAssertEqual(IntentClassifier.UserIntent.simpleQuestion.rawValue, "simpleQuestion")
        XCTAssertEqual(IntentClassifier.UserIntent.complexReasoning.rawValue, "complexReasoning")
        XCTAssertEqual(IntentClassifier.UserIntent.directiveCreation.rawValue, "directiveCreation")
    }

    // MARK: - Classification Result

    /// ClassificationResult captures all fields.
    func testClassificationResult() {
        let result = IntentClassifier.ClassificationResult(
            intent: .simpleQuestion,
            confidence: 0.85,
            method: .llm
        )
        XCTAssertEqual(result.intent, .simpleQuestion)
        XCTAssertEqual(result.confidence, 0.85)
        XCTAssertEqual(result.method, .llm)
    }

    /// ClassificationResult is Equatable.
    func testClassificationResultEquatable() {
        let r1 = IntentClassifier.ClassificationResult(intent: .memorySearch, confidence: 0.7, method: .heuristic)
        let r2 = IntentClassifier.ClassificationResult(intent: .memorySearch, confidence: 0.7, method: .heuristic)
        XCTAssertEqual(r1, r2)
    }

    // MARK: - Intent String Parsing

    /// parseIntentString handles exact matches.
    func testParseExactMatch() {
        XCTAssertEqual(IntentClassifier.parseIntentString("simpleQuestion"), .simpleQuestion)
        XCTAssertEqual(IntentClassifier.parseIntentString("memorySearch"), .memorySearch)
        XCTAssertEqual(IntentClassifier.parseIntentString("procedureReplay"), .procedureReplay)
        XCTAssertEqual(IntentClassifier.parseIntentString("procedureLearning"), .procedureLearning)
        XCTAssertEqual(IntentClassifier.parseIntentString("complexReasoning"), .complexReasoning)
        XCTAssertEqual(IntentClassifier.parseIntentString("directiveCreation"), .directiveCreation)
        XCTAssertEqual(IntentClassifier.parseIntentString("ambiguous"), .ambiguous)
    }

    /// parseIntentString is case-insensitive.
    func testParseCaseInsensitive() {
        XCTAssertEqual(IntentClassifier.parseIntentString("SIMPLEQUESTION"), .simpleQuestion)
        XCTAssertEqual(IntentClassifier.parseIntentString("MemorySearch"), .memorySearch)
    }

    /// parseIntentString handles underscores and spaces.
    func testParseWithSeparators() {
        XCTAssertEqual(IntentClassifier.parseIntentString("simple_question"), .simpleQuestion)
        XCTAssertEqual(IntentClassifier.parseIntentString("memory search"), .memorySearch)
        XCTAssertEqual(IntentClassifier.parseIntentString("procedure_replay"), .procedureReplay)
    }

    /// parseIntentString handles partial matches.
    func testParsePartialMatch() {
        XCTAssertEqual(IntentClassifier.parseIntentString("It's a question"), .simpleQuestion)
        XCTAssertEqual(IntentClassifier.parseIntentString("needs search"), .memorySearch)
        XCTAssertEqual(IntentClassifier.parseIntentString("this is ambiguous"), .ambiguous)
    }

    /// parseIntentString returns nil for unknown strings.
    func testParseUnknown() {
        XCTAssertNil(IntentClassifier.parseIntentString("completely unrelated"))
        XCTAssertNil(IntentClassifier.parseIntentString(""))
    }

    // MARK: - Heuristic Classification

    /// Heuristic detects directive creation.
    func testHeuristicDirective() {
        let result = IntentClassifier.classifyViaHeuristic(query: "Remind me when I open Slack")
        XCTAssertEqual(result.intent, .directiveCreation)
        XCTAssertEqual(result.method, .heuristic)
    }

    /// Heuristic detects procedure learning.
    func testHeuristicProcedureLearning() {
        let result = IntentClassifier.classifyViaHeuristic(query: "Watch me do this and learn")
        XCTAssertEqual(result.intent, .procedureLearning)
        XCTAssertEqual(result.method, .heuristic)
    }

    /// Heuristic detects procedure replay.
    func testHeuristicProcedureReplay() {
        let result = IntentClassifier.classifyViaHeuristic(query: "File my expense report for last week")
        XCTAssertEqual(result.intent, .procedureReplay)
        XCTAssertEqual(result.method, .heuristic)
    }

    /// Heuristic detects complex reasoning.
    func testHeuristicComplexReasoning() {
        let result = IntentClassifier.classifyViaHeuristic(query: "Analyze my time allocation this week")
        XCTAssertEqual(result.intent, .complexReasoning)
        XCTAssertEqual(result.method, .heuristic)
    }

    /// Heuristic detects memory search.
    func testHeuristicMemorySearch() {
        let result = IntentClassifier.classifyViaHeuristic(query: "Find all mentions of the budget meeting")
        XCTAssertEqual(result.intent, .memorySearch)
        XCTAssertEqual(result.method, .heuristic)
    }

    /// Heuristic detects simple question.
    func testHeuristicSimpleQuestion() {
        let result = IntentClassifier.classifyViaHeuristic(query: "What was I doing at 2pm?")
        XCTAssertEqual(result.intent, .simpleQuestion)
        XCTAssertEqual(result.method, .heuristic)
    }

    /// Short unknown queries default to simple question.
    func testHeuristicShortDefault() {
        let result = IntentClassifier.classifyViaHeuristic(query: "hello")
        XCTAssertEqual(result.intent, .simpleQuestion)
        XCTAssertEqual(result.confidence, 0.4)
    }

    /// Long unknown queries default to ambiguous.
    func testHeuristicLongDefault() {
        let result = IntentClassifier.classifyViaHeuristic(
            query: "I need to do something really specific with a complicated workflow that involves multiple steps"
        )
        XCTAssertEqual(result.intent, .ambiguous)
        XCTAssertEqual(result.method, .defaultFallback)
    }

    // MARK: - LLM Classification

    /// classify uses LLM function when provided.
    func testClassifyViaLLM() async {
        let classifyFn: @Sendable (String) async throws -> String = { _ in
            "complexReasoning"
        }

        let result = await IntentClassifier.classify(
            query: "test query",
            classifyFn: classifyFn
        )
        XCTAssertEqual(result.intent, .complexReasoning)
        XCTAssertEqual(result.method, .llm)
        XCTAssertEqual(result.confidence, 0.85)
    }

    /// classify falls back to heuristic when LLM fails.
    func testClassifyFallbackOnLLMError() async {
        let classifyFn: @Sendable (String) async throws -> String = { _ in
            throw NSError(domain: "test", code: 1)
        }

        let result = await IntentClassifier.classify(
            query: "What was I doing at 2pm?",
            classifyFn: classifyFn
        )
        XCTAssertEqual(result.intent, .simpleQuestion)
        XCTAssertEqual(result.method, .heuristic)
    }

    /// classify falls back to heuristic when LLM returns garbage.
    func testClassifyFallbackOnBadLLMOutput() async {
        let classifyFn: @Sendable (String) async throws -> String = { _ in
            "I think this is a really interesting question about data science"
        }

        let result = await IntentClassifier.classify(
            query: "What was I doing at 2pm?",
            classifyFn: classifyFn
        )
        XCTAssertEqual(result.method, .heuristic)
    }

    /// classify without any classifier uses heuristic.
    func testClassifyNoClassifier() async {
        let result = await IntentClassifier.classify(query: "Find my expense report")
        XCTAssertEqual(result.intent, .memorySearch) // "find" keyword
        XCTAssertEqual(result.method, .heuristic)
    }

    // MARK: - Classification Method

    /// ClassificationMethod raw values.
    func testClassificationMethodRawValues() {
        XCTAssertEqual(IntentClassifier.ClassificationMethod.llm.rawValue, "llm")
        XCTAssertEqual(IntentClassifier.ClassificationMethod.heuristic.rawValue, "heuristic")
        XCTAssertEqual(IntentClassifier.ClassificationMethod.defaultFallback.rawValue, "defaultFallback")
    }
}
