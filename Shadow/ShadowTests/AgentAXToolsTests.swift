import XCTest
@testable import Shadow

final class AgentAXToolsTests: XCTestCase {

    // MARK: - Tool Registration

    /// All 14 AX tools are registered when calling registerAXTools.
    func testAllAXToolsRegistered() {
        var tools: [String: RegisteredTool] = [:]
        AgentTools.registerAXTools(into: &tools)

        let expectedTools = [
            "ax_tree_query", "ax_click", "ax_type", "ax_hotkey", "ax_scroll",
            "ax_wait", "ax_focus_app", "ax_read_text",
            "ax_inspect", "ax_element_at", "ax_list_apps",
            "capture_live_screenshot",
            "get_procedures", "replay_procedure"
        ]
        for name in expectedTools {
            XCTAssertNotNil(tools[name], "Missing tool: \(name)")
        }
        XCTAssertEqual(tools.count, 14)
    }

    /// AX and procedure tools are included in the default registry.
    func testAXToolsInDefaultRegistry() {
        let registry = AgentTools.buildDefaultRegistry()
        let specs = registry.toolSpecs
        let names = Set(specs.map(\.name))

        XCTAssertTrue(names.contains("ax_tree_query"))
        XCTAssertTrue(names.contains("ax_click"))
        XCTAssertTrue(names.contains("ax_type"))
        XCTAssertTrue(names.contains("ax_hotkey"))
        XCTAssertTrue(names.contains("ax_scroll"))
        XCTAssertTrue(names.contains("ax_wait"))
        XCTAssertTrue(names.contains("ax_focus_app"))
        XCTAssertTrue(names.contains("ax_read_text"))
        XCTAssertTrue(names.contains("ax_inspect"))
        XCTAssertTrue(names.contains("ax_element_at"))
        XCTAssertTrue(names.contains("ax_list_apps"))
        XCTAssertTrue(names.contains("get_procedures"))
        XCTAssertTrue(names.contains("replay_procedure"))
    }

    // MARK: - ax_tree_query Specs

    /// ax_tree_query has the correct spec structure.
    func testAxTreeQuerySpec() {
        let tool = AgentTools.axTreeQueryTool()
        XCTAssertEqual(tool.spec.name, "ax_tree_query")
        XCTAssertTrue(tool.spec.description.contains("accessibility tree"))
        XCTAssertNotNil(tool.handler)
        XCTAssertNil(tool.imageHandler)
    }

    /// ax_tree_query with no frontmost app returns error message (not a throw).
    func testAxTreeQueryNoApp() async throws {
        let tool = AgentTools.axTreeQueryTool(
            appProvider: { nil }
        )

        let result = try await tool.handler!([:])
        XCTAssertTrue(result.contains("No frontmost application"))
    }

    // MARK: - ax_click Specs

    /// ax_click has the correct spec structure.
    func testAxClickSpec() {
        let tool = AgentTools.axClickTool()
        XCTAssertEqual(tool.spec.name, "ax_click")
        XCTAssertTrue(tool.spec.description.contains("Click"))
        XCTAssertNotNil(tool.handler)
    }

    /// ax_click with missing query and coordinates throws error.
    func testAxClickMissingArgs() async {
        let tool = AgentTools.axClickTool(
            appProvider: { nil }
        )

        do {
            _ = try await tool.handler!([:])
            XCTFail("Should throw for missing query and coordinates")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("query") || error.localizedDescription.contains("x/y"))
        }
    }

    /// ax_click with no app returns error for query-based click.
    func testAxClickNoApp() async {
        let tool = AgentTools.axClickTool(
            appProvider: { nil }
        )

        let result = try? await tool.handler!(["query": .string("OK")])
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("No frontmost application") ?? false)
    }

    // MARK: - ax_type Specs

    /// ax_type has the correct spec structure.
    func testAxTypeSpec() {
        let tool = AgentTools.axTypeTool()
        XCTAssertEqual(tool.spec.name, "ax_type")
        XCTAssertTrue(tool.spec.description.contains("text"))
        XCTAssertNotNil(tool.handler)
    }

    /// ax_type requires 'text' argument.
    func testAxTypeMissingText() async {
        let tool = AgentTools.axTypeTool()

        do {
            _ = try await tool.handler!([:])
            XCTFail("Should throw for missing text")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("text"))
        }
    }

    /// ax_type with no frontmost app returns error.
    func testAxTypeNoApp() async {
        let tool = AgentTools.axTypeTool(
            appProvider: { nil }
        )

        let result = try? await tool.handler!(["text": .string("hello")])
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("No frontmost application") ?? false)
    }

    // MARK: - ax_hotkey Specs

    /// ax_hotkey has the correct spec structure.
    func testAxHotkeySpec() {
        let tool = AgentTools.axHotkeyTool()
        XCTAssertEqual(tool.spec.name, "ax_hotkey")
        XCTAssertTrue(tool.spec.description.contains("keyboard shortcut"))
        XCTAssertNotNil(tool.handler)
    }

    /// ax_hotkey requires 'keys' argument.
    func testAxHotkeyMissingKeys() async {
        let tool = AgentTools.axHotkeyTool()

        do {
            _ = try await tool.handler!([:])
            XCTFail("Should throw for missing keys")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("keys"))
        }
    }

    /// ax_hotkey with empty keys array throws.
    func testAxHotkeyEmptyKeys() async {
        let tool = AgentTools.axHotkeyTool()

        do {
            _ = try await tool.handler!(["keys": .array([])])
            XCTFail("Should throw for empty keys")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("key"))
        }
    }

    // MARK: - ax_scroll Specs

    /// ax_scroll has the correct spec structure.
    func testAxScrollSpec() {
        let tool = AgentTools.axScrollTool()
        XCTAssertEqual(tool.spec.name, "ax_scroll")
        XCTAssertTrue(tool.spec.description.contains("Scroll"))
        XCTAssertNotNil(tool.handler)
    }

    /// ax_scroll requires 'direction' argument.
    func testAxScrollMissingDirection() async {
        let tool = AgentTools.axScrollTool()

        do {
            _ = try await tool.handler!([:])
            XCTFail("Should throw for missing direction")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("direction"))
        }
    }

    /// ax_scroll rejects invalid direction.
    func testAxScrollInvalidDirection() async {
        let tool = AgentTools.axScrollTool()

        do {
            _ = try await tool.handler!(["direction": .string("diagonal")])
            XCTFail("Should throw for invalid direction")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("direction"))
        }
    }

    // MARK: - Tool Count Verification

    /// Default registry has all expected tools (V1 read-only + AX action + procedure).
    func testTotalToolCount() {
        let registry = AgentTools.buildDefaultRegistry()
        let specs = registry.toolSpecs

        // V1 tools (9): search_hybrid, get_transcript_window, get_timeline_context,
        //                get_day_summary, resolve_latest_meeting, get_activity_sequence,
        //                search_summaries, search_visual_memories, inspect_screenshots
        // AX tools (12): ax_tree_query, ax_click, ax_type, ax_hotkey, ax_scroll,
        //                ax_wait, ax_focus_app, ax_read_text,
        //                ax_inspect, ax_element_at, ax_list_apps,
        //                capture_live_screenshot
        // Procedure tools (2): get_procedures, replay_procedure
        // Memory tools (3): get_knowledge, set_directive, get_directives
        XCTAssertEqual(specs.count, 26, "Expected 9 V1 + 12 AX + 2 procedure + 3 memory = 26 total")
    }

    /// Tool names are unique (no duplicates).
    func testToolNamesUnique() {
        let registry = AgentTools.buildDefaultRegistry()
        let specs = registry.toolSpecs
        let names = specs.map(\.name)
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count, "Duplicate tool names detected")
    }

    /// Tool specs are sorted alphabetically (deterministic for LLM requests).
    func testToolSpecsSorted() {
        let registry = AgentTools.buildDefaultRegistry()
        let specs = registry.toolSpecs
        let names = specs.map(\.name)
        XCTAssertEqual(names, names.sorted())
    }

    // MARK: - ax_inspect

    /// ax_inspect spec is correct.
    func testAxInspectSpec() {
        let tool = AgentTools.axInspectTool()
        XCTAssertEqual(tool.spec.name, "ax_inspect")
        XCTAssertTrue(tool.spec.description.contains("metadata"))
        XCTAssertNotNil(tool.handler)
    }

    /// ax_inspect missing query throws.
    func testAxInspectMissingQuery() async {
        let tool = AgentTools.axInspectTool(appProvider: { nil })
        do {
            let _ = try await tool.handler!([:])
            XCTFail("Expected ToolError")
        } catch let error as ToolError {
            if case .missingArgument(let name) = error {
                XCTAssertEqual(name, "query")
            } else {
                XCTFail("Expected missingArgument, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// ax_inspect with no frontmost app returns error.
    func testAxInspectNoApp() async throws {
        let tool = AgentTools.axInspectTool(appProvider: { nil })
        let result = try await tool.handler!(["query": AnyCodable.string("test")])
        XCTAssertTrue(result.contains("No frontmost application"))
    }

    // MARK: - ax_element_at

    /// ax_element_at spec is correct.
    func testAxElementAtSpec() {
        let tool = AgentTools.axElementAtTool()
        XCTAssertEqual(tool.spec.name, "ax_element_at")
        XCTAssertTrue(tool.spec.description.contains("coordinates"))
        XCTAssertNotNil(tool.handler)
    }

    /// ax_element_at missing args throws.
    func testAxElementAtMissingArgs() async {
        let tool = AgentTools.axElementAtTool(appProvider: { nil })
        do {
            let _ = try await tool.handler!([:])
            XCTFail("Expected ToolError")
        } catch let error as ToolError {
            if case .missingArgument = error {
                // correct
            } else {
                XCTFail("Expected missingArgument, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// ax_element_at with no frontmost app returns error.
    func testAxElementAtNoApp() async throws {
        let tool = AgentTools.axElementAtTool(appProvider: { nil })
        let result = try await tool.handler!([
            "x": AnyCodable.double(100),
            "y": AnyCodable.double(100)
        ])
        XCTAssertTrue(result.contains("No frontmost application"))
    }

    // MARK: - ax_list_apps

    /// ax_list_apps spec is correct.
    func testAxListAppsSpec() {
        let tool = AgentTools.axListAppsTool()
        XCTAssertEqual(tool.spec.name, "ax_list_apps")
        XCTAssertTrue(tool.spec.description.contains("running applications"))
        XCTAssertNotNil(tool.handler)
    }

    /// ax_list_apps returns non-empty result on a running macOS system.
    func testAxListAppsReturnsResults() async throws {
        let tool = AgentTools.axListAppsTool()
        let result = try await tool.handler!([:])
        // On a running macOS system, there should always be at least one app
        XCTAssertFalse(result.isEmpty)
        // Should not contain Shadow itself
        XCTAssertFalse(result.contains("\"name\":\"Shadow\""))
    }

    // MARK: - Screenshot Verification

    /// ScreenshotVerifier uses the correct Haiku model ID.
    func testScreenshotVerifierModelId() {
        XCTAssertEqual(ScreenshotVerifier.verificationModelId, "claude-haiku-4-5-20251001")
    }

    /// ax_click accepts an orchestrator parameter for verification.
    func testAxClickAcceptsOrchestrator() {
        // Verify the tool can be created with an orchestrator (nil = no verification)
        let toolNoVerify = AgentTools.axClickTool(orchestrator: nil)
        XCTAssertEqual(toolNoVerify.spec.name, "ax_click")
        XCTAssertNotNil(toolNoVerify.handler)
    }

    /// ax_click without orchestrator does not include verification line.
    func testAxClickNoVerification() async throws {
        let tool = AgentTools.axClickTool(
            appProvider: { nil },
            orchestrator: nil
        )
        // Query-based click with no app — should return "No frontmost application"
        let result = try? await tool.handler!(["query": .string("OK")])
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.contains("verification") ?? true)
    }

    /// registerAXTools accepts an orchestrator parameter.
    func testRegisterAXToolsAcceptsOrchestrator() {
        var tools: [String: RegisteredTool] = [:]
        AgentTools.registerAXTools(into: &tools, orchestrator: nil)
        XCTAssertEqual(tools.count, 14)
    }

    /// buildDefaultRegistry accepts an orchestrator parameter.
    func testBuildDefaultRegistryAcceptsOrchestrator() {
        let registry = AgentTools.buildDefaultRegistry(orchestrator: nil)
        let specs = registry.toolSpecs
        XCTAssertTrue(specs.contains { $0.name == "ax_click" })
    }
}
