import XCTest
@testable import Shadow

final class MemoryQueryPlannerTests: XCTestCase {

    // MARK: - Heuristic Planning

    /// Preference keywords trigger semantic_knowledge query with preference category.
    func testHeuristicPlanPreference() async {
        let queries = await MemoryQueryPlanner.plan(question: "What theme does the user prefer?")
        let sources = queries.map { $0.source }
        XCTAssertTrue(sources.contains(.semanticKnowledge))
        // Should have preference category filter
        let skQuery = queries.first { $0.source == .semanticKnowledge }
        XCTAssertEqual(skQuery?.category, "preference")
    }

    /// Reminder keywords trigger directives query.
    func testHeuristicPlanDirective() async {
        let queries = await MemoryQueryPlanner.plan(question: "Remind me to check email when I open Safari")
        let sources = queries.map { $0.source }
        XCTAssertTrue(sources.contains(.directives))
    }

    /// Recent activity keywords trigger episodes query.
    func testHeuristicPlanRecent() async {
        let queries = await MemoryQueryPlanner.plan(question: "What was I doing recently?")
        let sources = queries.map { $0.source }
        XCTAssertTrue(sources.contains(.episodes))
    }

    /// Unknown question triggers default (all sources).
    func testHeuristicPlanDefault() async {
        let queries = await MemoryQueryPlanner.plan(question: "xyz unknown query")
        XCTAssertEqual(queries.count, 3)
        let sources = Set(queries.map { $0.source })
        XCTAssertTrue(sources.contains(.semanticKnowledge))
        XCTAssertTrue(sources.contains(.directives))
        XCTAssertTrue(sources.contains(.episodes))
    }

    /// Multiple keywords combine into multiple queries.
    func testHeuristicPlanMultipleKeywords() async {
        let queries = await MemoryQueryPlanner.plan(question: "Remind me of my preferred setting from yesterday")
        let sources = Set(queries.map { $0.source })
        // Should include directives (remind), preferences (preferred), and episodes (yesterday)
        XCTAssertTrue(sources.contains(.directives))
        XCTAssertTrue(sources.contains(.semanticKnowledge))
        XCTAssertTrue(sources.contains(.episodes))
    }

    // MARK: - Query Execution

    /// Execute queries semantic knowledge source.
    func testExecuteSemanticKnowledge() throws {
        let plan: [MemoryQueryPlanner.MemoryQuery] = [
            .init(source: .semanticKnowledge, category: "fact", keywords: [], timeRangeUs: nil, limit: 5)
        ]

        let queryFn: SemanticMemoryStore.QueryFn = { cat, lim in
            XCTAssertEqual(cat, "fact")
            XCTAssertEqual(lim, 5)
            return [
                SemanticKnowledgeRecord(
                    id: "sk-1", category: "fact", key: "editor", value: "VS Code",
                    confidence: 0.9, sourceEpisodeIds: "ep-1",
                    createdAt: 1000000, updatedAt: 2000000,
                    accessCount: 0, lastAccessedAt: nil
                )
            ]
        }

        let results = try MemoryQueryPlanner.execute(
            plan: plan,
            knowledgeQueryFn: queryFn
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].source, .semanticKnowledge)
        XCTAssertEqual(results[0].entries.count, 1)
        XCTAssertEqual(results[0].entries[0].key, "editor")
        XCTAssertEqual(results[0].entries[0].summary, "VS Code")
    }

    /// Execute queries directives source.
    func testExecuteDirectives() throws {
        let plan: [MemoryQueryPlanner.MemoryQuery] = [
            .init(source: .directives, category: nil, keywords: [], timeRangeUs: nil, limit: 10)
        ]

        let directiveQueryFn: DirectiveMemoryStore.QueryActiveFn = { _, lim in
            XCTAssertEqual(lim, 10)
            return [
                DirectiveRecord(
                    id: "dir-1", directiveType: "reminder",
                    triggerPattern: "opens Slack", actionDescription: "Check standup",
                    priority: 5, createdAt: 1000000, expiresAt: nil,
                    isActive: true, executionCount: 0, lastTriggeredAt: nil,
                    sourceContext: "test"
                )
            ]
        }

        let results = try MemoryQueryPlanner.execute(
            plan: plan,
            directiveQueryFn: directiveQueryFn
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].source, .directives)
        XCTAssertEqual(results[0].entries.count, 1)
        XCTAssertEqual(results[0].entries[0].key, "opens Slack")
    }

    /// Execute with empty plan returns empty results.
    func testExecuteEmptyPlan() throws {
        let results = try MemoryQueryPlanner.execute(
            plan: [],
            knowledgeQueryFn: { _, _ in [] },
            directiveQueryFn: { _, _ in [] }
        )
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Format for Context

    /// Formatting produces text with section headers.
    func testFormatForContextSections() {
        let results = [
            MemoryQueryPlanner.MemoryQueryResult(
                source: .semanticKnowledge,
                entries: [
                    MemoryQueryPlanner.MemoryEntry(
                        id: "sk-1", category: "fact", key: "editor",
                        summary: "Uses VS Code daily", confidence: 0.9, timestamp: 1000000
                    )
                ]
            )
        ]

        let text = MemoryQueryPlanner.formatForContext(results: results)
        XCTAssertTrue(text.contains("[semantic_knowledge]"))
        XCTAssertTrue(text.contains("editor"))
        XCTAssertTrue(text.contains("Uses VS Code daily"))
    }

    /// Formatting respects maxChars budget.
    func testFormatForContextBudget() {
        let longEntry = MemoryQueryPlanner.MemoryEntry(
            id: "sk-1", category: "fact", key: "test",
            summary: String(repeating: "x", count: 5000),
            confidence: 0.9, timestamp: 1000000
        )

        let results = [
            MemoryQueryPlanner.MemoryQueryResult(
                source: .semanticKnowledge,
                entries: [longEntry, longEntry, longEntry]
            )
        ]

        let text = MemoryQueryPlanner.formatForContext(results: results, maxChars: 200)
        XCTAssertLessThanOrEqual(text.count, 200)
    }

    /// Formatting skips empty results.
    func testFormatForContextSkipsEmpty() {
        let results = [
            MemoryQueryPlanner.MemoryQueryResult(source: .semanticKnowledge, entries: []),
            MemoryQueryPlanner.MemoryQueryResult(
                source: .directives,
                entries: [
                    MemoryQueryPlanner.MemoryEntry(
                        id: "dir-1", category: "reminder", key: "trigger",
                        summary: "action", confidence: 1.0, timestamp: 1000000
                    )
                ]
            )
        ]

        let text = MemoryQueryPlanner.formatForContext(results: results)
        XCTAssertFalse(text.contains("[semantic_knowledge]"))
        XCTAssertTrue(text.contains("[directives]"))
    }

    // MARK: - MemoryQuery Equatable

    /// MemoryQuery equality works.
    func testMemoryQueryEquality() {
        let q1 = MemoryQueryPlanner.MemoryQuery(
            source: .semanticKnowledge, category: "fact", keywords: ["test"], timeRangeUs: nil, limit: 10
        )
        let q2 = MemoryQueryPlanner.MemoryQuery(
            source: .semanticKnowledge, category: "fact", keywords: ["test"], timeRangeUs: nil, limit: 10
        )
        XCTAssertEqual(q1, q2)
    }

    /// MemorySource raw values are correct.
    func testMemorySourceRawValues() {
        XCTAssertEqual(MemoryQueryPlanner.MemorySource.semanticKnowledge.rawValue, "semantic_knowledge")
        XCTAssertEqual(MemoryQueryPlanner.MemorySource.directives.rawValue, "directives")
        XCTAssertEqual(MemoryQueryPlanner.MemorySource.episodes.rawValue, "episodes")
        XCTAssertEqual(MemoryQueryPlanner.MemorySource.procedures.rawValue, "procedures")
    }
}
