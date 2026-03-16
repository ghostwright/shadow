import XCTest
@testable import Shadow

/// Thread-safe box for capturing values in @Sendable closures during tests.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class AgentMemoryToolsTests: XCTestCase {

    // MARK: - Tool Registration

    /// Memory tools are registered into the tool dictionary.
    func testAllMemoryToolsRegistered() {
        var tools: [String: RegisteredTool] = [:]
        AgentTools.registerMemoryTools(into: &tools)

        XCTAssertEqual(tools.count, 3)
        XCTAssertNotNil(tools["get_knowledge"])
        XCTAssertNotNil(tools["set_directive"])
        XCTAssertNotNil(tools["get_directives"])
    }

    /// Total tool count includes memory tools.
    func testTotalToolCountWithMemoryTools() {
        let registry = AgentTools.buildDefaultRegistry()
        let specs = registry.toolSpecs
        // V1 tools (9) + AX tools (12) + procedure tools (2) + memory tools (3) = 26
        XCTAssertEqual(specs.count, 26)
    }

    /// Memory tools appear in default registry.
    func testMemoryToolsInDefaultRegistry() {
        let registry = AgentTools.buildDefaultRegistry()
        let names = Set(registry.toolSpecs.map(\.name))
        XCTAssertTrue(names.contains("get_knowledge"))
        XCTAssertTrue(names.contains("set_directive"))
        XCTAssertTrue(names.contains("get_directives"))
    }

    // MARK: - get_knowledge Tool

    /// get_knowledge spec is correct.
    func testGetKnowledgeSpec() {
        let tool = AgentTools.getKnowledgeTool()
        XCTAssertEqual(tool.spec.name, "get_knowledge")
        XCTAssertTrue(tool.spec.description.contains("semantic memory"))
        XCTAssertNotNil(tool.handler)
    }

    /// get_knowledge returns formatted knowledge entries.
    func testGetKnowledgeReturnsEntries() async throws {
        let queryFn: SemanticMemoryStore.QueryFn = { _, _ in
            [
                SemanticKnowledgeRecord(
                    id: "sk-1", category: "fact", key: "editor", value: "VS Code",
                    confidence: 0.9, sourceEpisodeIds: "ep-1",
                    createdAt: 1000000, updatedAt: 2000000,
                    accessCount: 5, lastAccessedAt: 1500000
                )
            ]
        }
        let touchFn: SemanticMemoryStore.TouchFn = { _, _ in }

        let tool = AgentTools.getKnowledgeTool(queryFn: queryFn, touchFn: touchFn)
        let result = try await tool.handler!([
            "category": .string("fact"),
            "limit": .int(10)
        ])

        XCTAssertTrue(result.contains("editor"))
        XCTAssertTrue(result.contains("VS Code"))
        XCTAssertTrue(result.contains("0.9"))
    }

    /// get_knowledge with no results returns appropriate message.
    func testGetKnowledgeEmpty() async throws {
        let queryFn: SemanticMemoryStore.QueryFn = { _, _ in [] }
        let touchFn: SemanticMemoryStore.TouchFn = { _, _ in }

        let tool = AgentTools.getKnowledgeTool(queryFn: queryFn, touchFn: touchFn)
        let result = try await tool.handler!([:])

        XCTAssertTrue(result.contains("no_knowledge_found"))
    }

    /// get_knowledge touches each accessed entry.
    func testGetKnowledgeTouchesEntries() async throws {
        let touchedIds = Box<[String]>([])

        let queryFn: SemanticMemoryStore.QueryFn = { _, _ in
            [
                SemanticKnowledgeRecord(
                    id: "sk-1", category: "fact", key: "test", value: "val",
                    confidence: 0.9, sourceEpisodeIds: "",
                    createdAt: 1000000, updatedAt: 2000000,
                    accessCount: 0, lastAccessedAt: nil
                ),
                SemanticKnowledgeRecord(
                    id: "sk-2", category: "fact", key: "test2", value: "val2",
                    confidence: 0.8, sourceEpisodeIds: "",
                    createdAt: 1000000, updatedAt: 2000000,
                    accessCount: 0, lastAccessedAt: nil
                )
            ]
        }
        let touchFn: SemanticMemoryStore.TouchFn = { id, _ in
            touchedIds.value.append(id)
        }

        let tool = AgentTools.getKnowledgeTool(queryFn: queryFn, touchFn: touchFn)
        _ = try await tool.handler!([:])

        XCTAssertEqual(touchedIds.value.count, 2)
        XCTAssertTrue(touchedIds.value.contains("sk-1"))
        XCTAssertTrue(touchedIds.value.contains("sk-2"))
    }

    // MARK: - set_directive Tool

    /// set_directive spec is correct.
    func testSetDirectiveSpec() {
        let tool = AgentTools.setDirectiveTool()
        XCTAssertEqual(tool.spec.name, "set_directive")
        XCTAssertTrue(tool.spec.description.contains("directive"))
        XCTAssertNotNil(tool.handler)
    }

    /// set_directive creates a directive with all parameters.
    func testSetDirectiveCreates() async throws {
        let captured = Box<(String, String, String, String, Int32, UInt64, UInt64?, String)?>(nil)

        let upsertFn: DirectiveMemoryStore.UpsertFn = { id, dirType, trigger, action, priority, created, expires, ctx in
            captured.value = (id, dirType, trigger, action, priority, created, expires, ctx)
        }

        let tool = AgentTools.setDirectiveTool(upsertFn: upsertFn)
        let result = try await tool.handler!([
            "type": .string("reminder"),
            "trigger": .string("opens Slack"),
            "action": .string("Check standup channel"),
            "priority": .int(8),
            "context": .string("morning routine"),
        ])

        XCTAssertTrue(result.contains("directive_created"))
        XCTAssertTrue(result.contains("reminder"))
        XCTAssertNotNil(captured.value)
        XCTAssertEqual(captured.value?.1, "reminder")
        XCTAssertEqual(captured.value?.2, "opens Slack")
        XCTAssertEqual(captured.value?.3, "Check standup channel")
        XCTAssertEqual(captured.value?.4, 8)
    }

    /// set_directive validates type parameter.
    func testSetDirectiveValidatesType() async {
        let upsertFn: DirectiveMemoryStore.UpsertFn = { _, _, _, _, _, _, _, _ in }

        let tool = AgentTools.setDirectiveTool(upsertFn: upsertFn)
        do {
            _ = try await tool.handler!([
                "type": .string("invalid_type"),
                "trigger": .string("test"),
                "action": .string("test"),
            ])
            XCTFail("Should throw for invalid type")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("type"))
        }
    }

    /// set_directive requires type, trigger, and action.
    func testSetDirectiveRequiresFields() async {
        let tool = AgentTools.setDirectiveTool()

        // Missing type
        do {
            _ = try await tool.handler!([
                "trigger": .string("test"),
                "action": .string("test"),
            ])
            XCTFail("Should throw for missing type")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("type"))
        }

        // Missing trigger
        do {
            _ = try await tool.handler!([
                "type": .string("reminder"),
                "action": .string("test"),
            ])
            XCTFail("Should throw for missing trigger")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("trigger"))
        }

        // Missing action
        do {
            _ = try await tool.handler!([
                "type": .string("reminder"),
                "trigger": .string("test"),
            ])
            XCTFail("Should throw for missing action")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("action"))
        }
    }

    /// set_directive with TTL sets expiresAt.
    func testSetDirectiveWithTTL() async throws {
        let capturedExpires = Box<UInt64?>(nil)

        let upsertFn: DirectiveMemoryStore.UpsertFn = { _, _, _, _, _, _, expires, _ in
            capturedExpires.value = expires
        }

        let tool = AgentTools.setDirectiveTool(upsertFn: upsertFn)
        _ = try await tool.handler!([
            "type": .string("reminder"),
            "trigger": .string("test"),
            "action": .string("test"),
            "ttlHours": .double(2.0),
        ])

        XCTAssertNotNil(capturedExpires.value)
        // Should be approximately 2 hours from now
        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let twoHoursUs: UInt64 = 2 * 3_600_000_000
        let diff = capturedExpires.value! > nowUs ? capturedExpires.value! - nowUs : nowUs - capturedExpires.value!
        XCTAssertLessThan(diff, twoHoursUs + 1_000_000) // within 1 second
    }

    // MARK: - get_directives Tool

    /// get_directives spec is correct.
    func testGetDirectivesSpec() {
        let tool = AgentTools.getDirectivesTool()
        XCTAssertEqual(tool.spec.name, "get_directives")
        XCTAssertTrue(tool.spec.description.contains("directive"))
        XCTAssertNotNil(tool.handler)
    }

    /// get_directives returns formatted directive entries.
    func testGetDirectivesReturnsEntries() async throws {
        let queryFn: DirectiveMemoryStore.QueryActiveFn = { _, _ in
            [
                DirectiveRecord(
                    id: "dir-1", directiveType: "reminder",
                    triggerPattern: "opens Slack", actionDescription: "Check standup",
                    priority: 5, createdAt: 1000000, expiresAt: nil,
                    isActive: true, executionCount: 3, lastTriggeredAt: 2000000,
                    sourceContext: "test"
                )
            ]
        }

        let tool = AgentTools.getDirectivesTool(queryFn: queryFn)
        let result = try await tool.handler!([:])

        XCTAssertTrue(result.contains("reminder"))
        XCTAssertTrue(result.contains("opens Slack"))
        XCTAssertTrue(result.contains("Check standup"))
    }

    /// get_directives with no active directives returns message.
    func testGetDirectivesEmpty() async throws {
        let queryFn: DirectiveMemoryStore.QueryActiveFn = { _, _ in [] }

        let tool = AgentTools.getDirectivesTool(queryFn: queryFn)
        let result = try await tool.handler!([:])

        XCTAssertTrue(result.contains("no_active_directives"))
    }
}
