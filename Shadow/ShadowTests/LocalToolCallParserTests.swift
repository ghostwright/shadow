import XCTest
@testable import Shadow

final class LocalToolCallParserTests: XCTestCase {

    // MARK: - Single Tool Call Parsing

    func testParseSingleToolCall() {
        let response = """
        I'll search for that information.

        <tool_call>
        {"name": "search_hybrid", "arguments": {"query": "meeting notes", "limit": 10}}
        </tool_call>
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(content, "I'll search for that information.")
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].name, "search_hybrid")
        XCTAssertEqual(toolCalls[0].arguments["query"], .string("meeting notes"))
        XCTAssertEqual(toolCalls[0].arguments["limit"], .int(10))
        XCTAssertFalse(toolCalls[0].id.isEmpty, "Tool call should have a generated UUID id")
    }

    // MARK: - Multiple Tool Calls

    func testParseMultipleToolCalls() {
        let response = """
        Let me search in two ways.

        <tool_call>
        {"name": "search_hybrid", "arguments": {"query": "budget report"}}
        </tool_call>
        <tool_call>
        {"name": "get_day_summary", "arguments": {"dateStr": "2026-02-23"}}
        </tool_call>
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(content, "Let me search in two ways.")
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].name, "search_hybrid")
        XCTAssertEqual(toolCalls[1].name, "get_day_summary")

        // Each tool call should have a unique ID
        XCTAssertNotEqual(toolCalls[0].id, toolCalls[1].id)
    }

    // MARK: - Content Extraction

    func testExtractTextContentBeforeToolCalls() {
        let response = """
        Here is my analysis of the situation.
        It involves multiple considerations.

        <tool_call>
        {"name": "search_hybrid", "arguments": {"query": "test"}}
        </tool_call>

        Some text after the tool call.
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        // Content is everything BEFORE the first <tool_call>
        XCTAssertTrue(content.contains("Here is my analysis"))
        XCTAssertTrue(content.contains("multiple considerations"))
        XCTAssertFalse(content.contains("Some text after"))
        XCTAssertEqual(toolCalls.count, 1)
    }

    // MARK: - Malformed JSON

    func testMalformedJSONInsideToolCallTag() {
        let response = """
        Trying to search.

        <tool_call>
        {"name": "search_hybrid", "arguments": {"query": "test
        </tool_call>
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        // Malformed JSON should be skipped, not crash
        XCTAssertEqual(content, "Trying to search.")
        XCTAssertEqual(toolCalls.count, 0)
    }

    // MARK: - Empty Response

    func testEmptyResponse() {
        let (content, toolCalls) = LocalToolCallParser.parse(response: "")

        XCTAssertEqual(content, "")
        XCTAssertEqual(toolCalls.count, 0)
    }

    // MARK: - Text Only (No Tool Calls)

    func testResponseWithOnlyText() {
        let response = "The meeting was about Q4 budget planning. No tools needed for this."

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(content, response)
        XCTAssertEqual(toolCalls.count, 0)
    }

    // MARK: - Unclosed Tag

    func testUnclosedToolCallTag() {
        let response = """
        Starting search.

        <tool_call>
        {"name": "search_hybrid", "arguments": {"query": "test"}}
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        // Unclosed tag: content is extracted, but no tool call parsed
        XCTAssertEqual(content, "Starting search.")
        XCTAssertEqual(toolCalls.count, 0)
    }

    // MARK: - Nested JSON in Arguments

    func testNestedJSONInArguments() {
        let response = """
        <tool_call>
        {"name": "complex_tool", "arguments": {"filter": {"app": "Safari", "nested": {"deep": true}}, "limit": 5}}
        </tool_call>
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(content, "")
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].name, "complex_tool")

        // Verify nested dictionary was parsed correctly
        if case .dictionary(let filter) = toolCalls[0].arguments["filter"] {
            XCTAssertEqual(filter["app"], .string("Safari"))
            if case .dictionary(let nested) = filter["nested"] {
                XCTAssertEqual(nested["deep"], .bool(true))
            } else {
                XCTFail("Expected nested dictionary")
            }
        } else {
            XCTFail("Expected dictionary for 'filter' argument")
        }

        XCTAssertEqual(toolCalls[0].arguments["limit"], .int(5))
    }

    // MARK: - Missing Name Field

    func testToolCallMissingNameField() {
        let response = """
        <tool_call>
        {"arguments": {"query": "test"}}
        </tool_call>
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(content, "")
        XCTAssertEqual(toolCalls.count, 0, "Tool call without name should be skipped")
    }

    // MARK: - Missing Arguments Field

    func testToolCallMissingArgumentsField() {
        let response = """
        <tool_call>
        {"name": "list_recent_apps"}
        </tool_call>
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(content, "")
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].name, "list_recent_apps")
        XCTAssertTrue(toolCalls[0].arguments.isEmpty, "Missing arguments should default to empty dict")
    }

    // MARK: - Tool Definition Formatting

    func testFormatToolDefinitions() {
        let tools: [ToolSpec] = [
            ToolSpec(
                name: "search_hybrid",
                description: "Search across all indexed content",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .dictionary([
                        "query": .dictionary([
                            "type": .string("string"),
                            "description": .string("Search query")
                        ]),
                        "limit": .dictionary([
                            "type": .string("integer"),
                            "description": .string("Max results")
                        ])
                    ])
                ]
            )
        ]

        let formatted = LocalToolCallParser.formatToolDefinitions(tools)

        XCTAssertTrue(formatted.contains("<tools>"), "Should contain tools block")
        XCTAssertTrue(formatted.contains("</tools>"), "Should close tools block")
        XCTAssertTrue(formatted.contains("search_hybrid"), "Should contain tool name")
        XCTAssertTrue(formatted.contains("Search across all indexed content"), "Should contain description")
        XCTAssertTrue(formatted.contains("<tool_call>"), "Should contain usage instructions")
        XCTAssertTrue(formatted.contains("\"type\":\"function\""), "Should have function type wrapper")
    }

    func testFormatToolDefinitionsEmpty() {
        let formatted = LocalToolCallParser.formatToolDefinitions([])
        XCTAssertEqual(formatted, "", "Empty tools should return empty string")
    }

    // MARK: - Whitespace Handling

    func testToolCallWithExtraWhitespace() {
        let response = """
        Content here.

        <tool_call>

          {"name": "search_hybrid", "arguments": {"query": "test"}}

        </tool_call>
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(content, "Content here.")
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].name, "search_hybrid")
    }

    // MARK: - Mixed Valid and Invalid Tool Calls

    func testMixedValidAndInvalidToolCalls() {
        let response = """
        Searching.

        <tool_call>
        {"name": "good_tool", "arguments": {"q": "test"}}
        </tool_call>
        <tool_call>
        {invalid json here}
        </tool_call>
        <tool_call>
        {"name": "another_good_tool", "arguments": {}}
        </tool_call>
        """

        let (content, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(content, "Searching.")
        XCTAssertEqual(toolCalls.count, 2, "Should skip invalid, keep valid")
        XCTAssertEqual(toolCalls[0].name, "good_tool")
        XCTAssertEqual(toolCalls[1].name, "another_good_tool")
    }

    // MARK: - Array Arguments

    func testToolCallWithArrayArgument() {
        let response = """
        <tool_call>
        {"name": "multi_search", "arguments": {"queries": ["alpha", "beta", "gamma"]}}
        </tool_call>
        """

        let (_, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(toolCalls.count, 1)
        if case .array(let queries) = toolCalls[0].arguments["queries"] {
            XCTAssertEqual(queries.count, 3)
            XCTAssertEqual(queries[0], .string("alpha"))
        } else {
            XCTFail("Expected array argument")
        }
    }

    // MARK: - Boolean and Null Arguments

    func testToolCallWithBoolAndNullArguments() {
        let response = """
        <tool_call>
        {"name": "config_tool", "arguments": {"enabled": true, "value": null, "count": 42}}
        </tool_call>
        """

        let (_, toolCalls) = LocalToolCallParser.parse(response: response)

        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].arguments["enabled"], .bool(true))
        XCTAssertEqual(toolCalls[0].arguments["value"], .null)
        XCTAssertEqual(toolCalls[0].arguments["count"], .int(42))
    }
}
