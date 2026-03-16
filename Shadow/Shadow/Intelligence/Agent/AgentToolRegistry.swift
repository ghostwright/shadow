import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AgentToolRegistry")

/// Signature for text-only tool handler functions.
/// Receives validated arguments, returns output string. Throws on failure.
typealias AgentToolHandler = @Sendable ([String: AnyCodable]) async throws -> String

/// Signature for image-capable tool handler functions.
/// Returns both text and optional images. Used by visual tools like inspect_screenshots.
typealias AgentImageToolHandler = @Sendable ([String: AnyCodable]) async throws -> AgentToolOutput

/// Output from an image-capable tool handler.
struct AgentToolOutput: Sendable {
    let text: String
    let images: [ImageData]

    init(text: String, images: [ImageData] = []) {
        self.text = text
        self.images = images
    }
}

/// A registered tool with its spec and handler.
/// Supports two handler patterns:
/// - `handler`: Text-only tools (existing 7 V1 tools)
/// - `imageHandler`: Image-capable tools (visual inspection)
struct RegisteredTool: Sendable {
    let spec: ToolSpec
    let handler: AgentToolHandler?
    let imageHandler: AgentImageToolHandler?

    /// Text-only tool constructor (existing pattern).
    init(spec: ToolSpec, handler: @escaping AgentToolHandler) {
        self.spec = spec
        self.handler = handler
        self.imageHandler = nil
    }

    /// Image-capable tool constructor.
    init(spec: ToolSpec, imageHandler: @escaping AgentImageToolHandler) {
        self.spec = spec
        self.handler = nil
        self.imageHandler = imageHandler
    }
}

/// Registry of tools available to the agent runtime.
/// Instantiated per-run — no shared mutation, no actor needed.
struct AgentToolRegistry: Sendable {
    private let tools: [String: RegisteredTool]
    private let maxOutputChars: Int

    init(tools: [String: RegisteredTool], maxOutputChars: Int = 12_000) {
        self.tools = tools
        self.maxOutputChars = maxOutputChars
    }

    /// All tool specs for inclusion in LLM requests.
    /// Sorted by name for deterministic ordering across runs.
    var toolSpecs: [ToolSpec] {
        tools.values.map(\.spec).sorted { $0.name < $1.name }
    }

    /// Whether the registry has any tools.
    var isEmpty: Bool {
        tools.isEmpty
    }

    /// Execute a tool call. Returns a ToolResult.
    /// Handles: unknown tool, output capping, error wrapping, image handlers.
    /// Never throws — errors are captured in the ToolResult.
    func execute(_ call: ToolCall) async -> ToolResult {
        guard let tool = tools[call.name] else {
            logger.warning("Unknown tool requested: \(call.name)")
            return ToolResult(
                toolCallId: call.id,
                content: "Unknown tool: \(call.name)",
                isError: true
            )
        }

        do {
            // Dispatch to image handler if present, otherwise text handler
            let toolOutput: AgentToolOutput
            if let imageHandler = tool.imageHandler {
                toolOutput = try await imageHandler(call.arguments)
            } else if let handler = tool.handler {
                let text = try await handler(call.arguments)
                toolOutput = AgentToolOutput(text: text)
            } else {
                return ToolResult(
                    toolCallId: call.id,
                    content: "Tool has no handler: \(call.name)",
                    isError: true
                )
            }

            // Cap text output size
            var output = toolOutput.text
            if output.count > maxOutputChars {
                output = String(output.prefix(maxOutputChars))
                    + "\n\n[truncated — output exceeded \(maxOutputChars) chars]"
            }

            return ToolResult(
                toolCallId: call.id,
                content: output,
                isError: false,
                images: toolOutput.images
            )
        } catch {
            logger.warning("Tool \(call.name) failed: \(error, privacy: .public)")
            return ToolResult(
                toolCallId: call.id,
                content: "Tool error: \(error.localizedDescription)",
                isError: true
            )
        }
    }
}
