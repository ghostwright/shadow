import XCTest
@testable import Shadow

final class AgentToolRegistryTests: XCTestCase {

    // 1. Execute a known tool — returns success result
    func testExecuteKnownTool() async {
        let tool = RegisteredTool(
            spec: ToolSpec(
                name: "greet",
                description: "Says hello",
                inputSchema: ["type": AnyCodable.string("object"), "properties": AnyCodable.dictionary([:]), "required": AnyCodable.array([])]
            ),
            handler: { args in
                let name = args["name"]?.stringValue ?? "world"
                return "Hello, \(name)!"
            }
        )
        let registry = AgentToolRegistry(tools: ["greet": tool])

        let call = ToolCall(id: "tc_1", name: "greet", arguments: ["name": AnyCodable.string("Shadow")])
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "Hello, Shadow!")
        XCTAssertEqual(result.toolCallId, "tc_1")
    }

    // 2. Unknown tool → isError true
    func testUnknownToolReturnsError() async {
        let registry = AgentToolRegistry(tools: [:])
        let call = ToolCall(id: "tc_2", name: "nonexistent", arguments: [:])
        let result = await registry.execute(call)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Unknown tool"))
        XCTAssertTrue(result.content.contains("nonexistent"))
    }

    // 3. Output truncation at maxOutputChars
    func testOutputTruncation() async {
        let tool = RegisteredTool(
            spec: ToolSpec(
                name: "verbose",
                description: "Returns a lot of text",
                inputSchema: ["type": AnyCodable.string("object"), "properties": AnyCodable.dictionary([:]), "required": AnyCodable.array([])]
            ),
            handler: { _ in
                String(repeating: "x", count: 500)
            }
        )
        // Set a low cap to test truncation
        let registry = AgentToolRegistry(tools: ["verbose": tool], maxOutputChars: 100)
        let call = ToolCall(id: "tc_3", name: "verbose", arguments: [:])
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("[truncated"))
        // The prefix should be exactly 100 chars of 'x', plus the truncation notice
        XCTAssertTrue(result.content.hasPrefix(String(repeating: "x", count: 100)))
        XCTAssertTrue(result.content.count < 500)
    }

    // 4. Handler throws → isError true, error message captured
    func testHandlerThrowReturnsError() async {
        let tool = RegisteredTool(
            spec: ToolSpec(
                name: "crasher",
                description: "Always throws",
                inputSchema: ["type": AnyCodable.string("object"), "properties": AnyCodable.dictionary([:]), "required": AnyCodable.array([])]
            ),
            handler: { _ in
                throw ToolError.invalidArgument("input", detail: "bad value")
            }
        )
        let registry = AgentToolRegistry(tools: ["crasher": tool])
        let call = ToolCall(id: "tc_4", name: "crasher", arguments: [:])
        let result = await registry.execute(call)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Tool error"))
    }

    // 5. toolSpecs returns all registered specs
    func testToolSpecsReturnsAll() {
        let specA = ToolSpec(
            name: "alpha",
            description: "First tool",
            inputSchema: ["type": AnyCodable.string("object"), "properties": AnyCodable.dictionary([:]), "required": AnyCodable.array([])]
        )
        let specB = ToolSpec(
            name: "beta",
            description: "Second tool",
            inputSchema: ["type": AnyCodable.string("object"), "properties": AnyCodable.dictionary([:]), "required": AnyCodable.array([])]
        )
        let registry = AgentToolRegistry(tools: [
            "alpha": RegisteredTool(spec: specA, handler: { _ in "" }),
            "beta": RegisteredTool(spec: specB, handler: { _ in "" }),
        ])

        let specs = registry.toolSpecs
        XCTAssertEqual(specs.count, 2)
        let names = Set(specs.map(\.name))
        XCTAssertTrue(names.contains("alpha"))
        XCTAssertTrue(names.contains("beta"))

        // isEmpty should be false
        XCTAssertFalse(registry.isEmpty)

        // Empty registry
        let empty = AgentToolRegistry(tools: [:])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.toolSpecs.count, 0)
    }

    // 6. Image handler tool returns images in ToolResult
    func testImageHandlerReturnsImages() async {
        let tool = RegisteredTool(
            spec: ToolSpec(
                name: "screenshot",
                description: "Returns a screenshot",
                inputSchema: ["type": AnyCodable.string("object"), "properties": AnyCodable.dictionary([:]), "required": AnyCodable.array([])]
            ),
            imageHandler: { _ in
                AgentToolOutput(
                    text: "Screenshot captured",
                    images: [ImageData(mediaType: "image/jpeg", base64Data: "dGVzdA==")]
                )
            }
        )
        let registry = AgentToolRegistry(tools: ["screenshot": tool])

        let call = ToolCall(id: "tc_img", name: "screenshot", arguments: [:])
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "Screenshot captured")
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images[0].mediaType, "image/jpeg")
        XCTAssertEqual(result.images[0].base64Data, "dGVzdA==")
    }

    // 7. Image handler output text is truncated at maxOutputChars
    func testImageHandlerOutputTruncation() async {
        let tool = RegisteredTool(
            spec: ToolSpec(
                name: "verbose_img",
                description: "Returns a lot of text with images",
                inputSchema: ["type": AnyCodable.string("object"), "properties": AnyCodable.dictionary([:]), "required": AnyCodable.array([])]
            ),
            imageHandler: { _ in
                AgentToolOutput(
                    text: String(repeating: "y", count: 500),
                    images: [ImageData(mediaType: "image/png", base64Data: "abc")]
                )
            }
        )
        let registry = AgentToolRegistry(tools: ["verbose_img": tool], maxOutputChars: 100)

        let call = ToolCall(id: "tc_trunc", name: "verbose_img", arguments: [:])
        let result = await registry.execute(call)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("[truncated"))
        // Images should still be passed through even when text is truncated
        XCTAssertEqual(result.images.count, 1)
    }

    // 8. toolSpecs returns deterministic order sorted by name
    func testToolSpecsDeterministicOrder() {
        let names = ["zeta", "alpha", "mu", "beta", "omega"]
        var tools: [String: RegisteredTool] = [:]
        for name in names {
            tools[name] = RegisteredTool(
                spec: ToolSpec(
                    name: name,
                    description: "\(name) tool",
                    inputSchema: ["type": AnyCodable.string("object"), "properties": AnyCodable.dictionary([:]), "required": AnyCodable.array([])]
                ),
                handler: { _ in "" }
            )
        }
        let registry = AgentToolRegistry(tools: tools)

        // Run multiple times to verify stability
        for _ in 0..<10 {
            let specs = registry.toolSpecs
            let specNames = specs.map(\.name)
            XCTAssertEqual(specNames, ["alpha", "beta", "mu", "omega", "zeta"],
                           "toolSpecs must be sorted by name for deterministic LLM requests")
        }
    }
}
