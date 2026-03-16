import XCTest
@testable import Shadow

final class SemanticConsolidatorTests: XCTestCase {

    // MARK: - Empty Input

    /// Consolidation with no episodes returns zero counts.
    func testConsolidateEmptyEpisodes() async throws {
        let result = try await SemanticConsolidator.consolidate(
            episodes: [],
            generate: mockGenerate(response: "[]")
        )
        XCTAssertEqual(result.newKnowledge, 0)
        XCTAssertEqual(result.updatedKnowledge, 0)
        XCTAssertEqual(result.episodesProcessed, 0)
    }

    // MARK: - Extraction

    /// Consolidation extracts new knowledge from episodes.
    func testConsolidateExtractsNew() async throws {
        let episodes = [makeEpisode(tags: ["coding"], apps: ["VS Code"])]
        var saved: [SemanticKnowledge] = []

        let llmResponse = """
        [
            {"category": "fact", "key": "primary_editor", "value": "VS Code", "confidence": 0.8},
            {"category": "skill", "key": "swift_development", "value": "Builds iOS apps in VS Code", "confidence": 0.6}
        ]
        """

        let result = try await SemanticConsolidator.consolidate(
            episodes: episodes,
            generate: mockGenerate(response: llmResponse),
            saveFn: { saved.append($0) }
        )

        XCTAssertEqual(result.newKnowledge, 2)
        XCTAssertEqual(result.updatedKnowledge, 0)
        XCTAssertEqual(result.episodesProcessed, 1)
        XCTAssertEqual(saved.count, 2)

        // Verify first extraction
        let factEntry = saved.first { $0.category == "fact" }
        XCTAssertNotNil(factEntry)
        XCTAssertEqual(factEntry?.key, "primary_editor")
        XCTAssertEqual(factEntry?.value, "VS Code")
        XCTAssertEqual(factEntry?.confidence ?? 0, 0.8, accuracy: 0.01)
    }

    // MARK: - Reinforcement

    /// Consolidation boosts confidence for existing knowledge.
    func testConsolidateReinforcesExisting() async throws {
        let episodes = [makeEpisode(tags: ["coding"], apps: ["VS Code"])]
        let existing = [
            SemanticKnowledge(
                id: "fact:primary_editor", category: "fact", key: "primary_editor",
                value: "VS Code", confidence: 0.7,
                sourceEpisodeIds: ["old-ep-1"],
                createdAt: 500000, updatedAt: 500000,
                accessCount: 5, lastAccessedAt: 400000
            )
        ]
        var saved: [SemanticKnowledge] = []

        let llmResponse = """
        [{"category": "fact", "key": "primary_editor", "value": "VS Code daily", "confidence": 0.9}]
        """

        let result = try await SemanticConsolidator.consolidate(
            episodes: episodes,
            existingKnowledge: existing,
            generate: mockGenerate(response: llmResponse),
            saveFn: { saved.append($0) }
        )

        XCTAssertEqual(result.newKnowledge, 0)
        XCTAssertEqual(result.updatedKnowledge, 1)
        XCTAssertEqual(saved.count, 1)

        // Confidence should be boosted (0.7 * 0.3 + 0.9 * 0.7 = 0.84)
        let updated = saved[0]
        XCTAssertEqual(updated.confidence, 0.84, accuracy: 0.01)
        // Should preserve original createdAt
        XCTAssertEqual(updated.createdAt, 500000)
        // Should preserve accessCount
        XCTAssertEqual(updated.accessCount, 5)
    }

    // MARK: - Invalid Input

    /// Invalid JSON from LLM produces zero extractions.
    func testConsolidateInvalidJSON() async throws {
        let episodes = [makeEpisode()]
        var saved: [SemanticKnowledge] = []

        let result = try await SemanticConsolidator.consolidate(
            episodes: episodes,
            generate: mockGenerate(response: "This is not JSON"),
            saveFn: { saved.append($0) }
        )

        XCTAssertEqual(result.newKnowledge, 0)
        XCTAssertEqual(saved.count, 0)
    }

    /// Invalid categories are filtered out.
    func testConsolidateFiltersBadCategories() async throws {
        let episodes = [makeEpisode()]
        var saved: [SemanticKnowledge] = []

        let llmResponse = """
        [
            {"category": "invalid_category", "key": "test", "value": "test", "confidence": 0.5},
            {"category": "fact", "key": "valid", "value": "valid value", "confidence": 0.7}
        ]
        """

        let result = try await SemanticConsolidator.consolidate(
            episodes: episodes,
            generate: mockGenerate(response: llmResponse),
            saveFn: { saved.append($0) }
        )

        XCTAssertEqual(result.newKnowledge, 1)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].category, "fact")
    }

    /// Empty key or value entries are filtered out.
    func testConsolidateFiltersEmpty() async throws {
        let episodes = [makeEpisode()]
        var saved: [SemanticKnowledge] = []

        let llmResponse = """
        [
            {"category": "fact", "key": "", "value": "no key", "confidence": 0.5},
            {"category": "fact", "key": "no_value", "value": "", "confidence": 0.5},
            {"category": "fact", "key": "valid", "value": "valid", "confidence": 0.5}
        ]
        """

        let result = try await SemanticConsolidator.consolidate(
            episodes: episodes,
            generate: mockGenerate(response: llmResponse),
            saveFn: { saved.append($0) }
        )

        XCTAssertEqual(result.newKnowledge, 1)
        XCTAssertEqual(saved[0].key, "valid")
    }

    /// Confidence is clamped to 0.0-1.0.
    func testConsolidateClampsConfidence() async throws {
        let episodes = [makeEpisode()]
        var saved: [SemanticKnowledge] = []

        let llmResponse = """
        [
            {"category": "fact", "key": "high", "value": "high conf", "confidence": 5.0},
            {"category": "fact", "key": "low", "value": "low conf", "confidence": -1.0}
        ]
        """

        _ = try await SemanticConsolidator.consolidate(
            episodes: episodes,
            generate: mockGenerate(response: llmResponse),
            saveFn: { saved.append($0) }
        )

        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.first { $0.key == "high" }?.confidence ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(saved.first { $0.key == "low" }?.confidence ?? 0, 0.0, accuracy: 0.001)
    }

    /// JSON embedded in markdown code blocks is extracted correctly.
    func testConsolidateMarkdownCodeBlock() async throws {
        let episodes = [makeEpisode()]
        var saved: [SemanticKnowledge] = []

        let llmResponse = """
        Here are the extracted facts:
        ```json
        [{"category": "fact", "key": "editor", "value": "VS Code", "confidence": 0.8}]
        ```
        """

        let result = try await SemanticConsolidator.consolidate(
            episodes: episodes,
            generate: mockGenerate(response: llmResponse),
            saveFn: { saved.append($0) }
        )

        XCTAssertEqual(result.newKnowledge, 1)
        XCTAssertEqual(saved[0].key, "editor")
    }

    // MARK: - Stable IDs

    /// Extracted knowledge uses stable IDs (category:key).
    func testConsolidateUsesStableIds() async throws {
        let episodes = [makeEpisode()]
        var saved: [SemanticKnowledge] = []

        let llmResponse = """
        [{"category": "preference", "key": "theme", "value": "dark", "confidence": 0.7}]
        """

        _ = try await SemanticConsolidator.consolidate(
            episodes: episodes,
            generate: mockGenerate(response: llmResponse),
            saveFn: { saved.append($0) }
        )

        XCTAssertEqual(saved[0].id, "preference:theme")
    }

    // MARK: - ConsolidationResult

    /// ConsolidationResult is Sendable.
    func testConsolidationResultSendable() {
        let result = SemanticConsolidator.ConsolidationResult(
            newKnowledge: 3, updatedKnowledge: 1, episodesProcessed: 2
        )
        // Verify fields
        XCTAssertEqual(result.newKnowledge, 3)
        XCTAssertEqual(result.updatedKnowledge, 1)
        XCTAssertEqual(result.episodesProcessed, 2)
    }

    // MARK: - Helpers

    private func makeEpisode(
        tags: [String] = ["test"],
        apps: [String] = ["TestApp"]
    ) -> EpisodeRecord {
        EpisodeRecord(
            id: UUID(),
            startUs: 1000000,
            endUs: 2000000,
            summary: "User was working in \(apps.joined(separator: ", "))",
            topicTags: tags,
            apps: apps,
            keyArtifacts: [],
            evidence: [],
            provenance: RecordProvenance(
                provider: "test", modelId: "test",
                generatedAt: Date(), inputHash: "test-hash"
            )
        )
    }

    private func mockGenerate(response: String) -> LLMGenerateFunction {
        { _ in
            LLMResponse(
                content: response,
                toolCalls: [],
                provider: "test",
                modelId: "test",
                inputTokens: nil,
                outputTokens: nil,
                latencyMs: 10
            )
        }
    }
}
