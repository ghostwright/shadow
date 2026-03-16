import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ContextBudgetManager")

/// Manages context window budgets for multi-agent orchestration.
///
/// The orchestrator maintains a sliding context window with three sections:
/// 1. System prompt (fixed, ~1500 tokens)
/// 2. Memory pack (variable, up to 4000 tokens)
/// 3. Conversation history (variable, remaining budget)
///
/// Each agent receives only the context it needs to minimize token usage
/// and prevent confusion from irrelevant information.
enum ContextBudgetManager {

    // MARK: - Budget Configuration

    /// Budget configuration for different model tiers.
    struct BudgetConfig: Sendable, Equatable {
        /// Total context window size in tokens.
        let totalTokenBudget: Int
        /// Maximum tokens for the system prompt section.
        let systemPromptBudget: Int
        /// Maximum tokens for the memory pack section.
        let memoryPackBudget: Int
        /// Maximum tokens for conversation history.
        var conversationBudget: Int {
            totalTokenBudget - systemPromptBudget - memoryPackBudget
        }
        /// Maximum characters per sub-agent context (prevents bloat).
        let maxSubAgentContextChars: Int
    }

    /// Preset budgets for known model tiers.
    static let cloudBudget = BudgetConfig(
        totalTokenBudget: 128_000,
        systemPromptBudget: 2_000,
        memoryPackBudget: 4_000,
        maxSubAgentContextChars: 32_000
    )

    static let localLargeBudget = BudgetConfig(
        totalTokenBudget: 32_000,
        systemPromptBudget: 1_500,
        memoryPackBudget: 2_000,
        maxSubAgentContextChars: 8_000
    )

    static let localSmallBudget = BudgetConfig(
        totalTokenBudget: 16_000,
        systemPromptBudget: 1_000,
        memoryPackBudget: 1_000,
        maxSubAgentContextChars: 4_000
    )

    // MARK: - Context Assembly

    /// Context assembled for a specific sub-agent.
    struct AgentContext: Sendable, Equatable {
        /// The agent role this context is for.
        let role: TaskDecomposer.AgentRole
        /// System prompt tailored for this agent.
        let systemPrompt: String
        /// Relevant context injected from other agents' results.
        let injectedContext: String
        /// Estimated token count for this context.
        let estimatedTokens: Int
    }

    /// Build context for a specific agent role.
    ///
    /// Each agent gets a focused system prompt and only the data it needs.
    /// The orchestrator is the only component with full context.
    ///
    /// - Parameters:
    ///   - role: The agent role to build context for.
    ///   - query: The original user query.
    ///   - priorResults: Results from previously completed sub-tasks.
    ///   - memoryPack: Memory pack text from ContextPacker (optional).
    ///   - budget: Budget configuration to respect.
    /// - Returns: Tailored AgentContext for the role.
    static func buildContext(
        role: TaskDecomposer.AgentRole,
        query: String,
        priorResults: [SubTaskResult] = [],
        memoryPack: String = "",
        budget: BudgetConfig = cloudBudget
    ) -> AgentContext {
        let systemPrompt = systemPromptForRole(role)

        // Build injected context from prior results, filtered by relevance
        var injectedParts: [String] = []

        // Add relevant prior results
        for result in priorResults {
            let relevant = isResultRelevant(result, forRole: role)
            if relevant {
                let truncated = String(result.output.prefix(budget.maxSubAgentContextChars / max(priorResults.count, 1)))
                injectedParts.append("[\(result.role.rawValue)] \(truncated)")
            }
        }

        // Add memory pack for roles that benefit from it
        if !memoryPack.isEmpty && roleUsesMemoryPack(role) {
            let memBudget = budget.memoryPackBudget * 4 // rough chars-to-tokens ratio
            let truncatedMem = String(memoryPack.prefix(memBudget))
            injectedParts.append("[memory_context]\n\(truncatedMem)")
        }

        let injectedContext = injectedParts.joined(separator: "\n\n")

        // Estimate tokens (rough: 4 chars per token)
        let totalChars = systemPrompt.count + injectedContext.count + query.count
        let estimatedTokens = totalChars / 4

        return AgentContext(
            role: role,
            systemPrompt: systemPrompt,
            injectedContext: injectedContext,
            estimatedTokens: estimatedTokens
        )
    }

    // MARK: - Role-Specific System Prompts

    /// Generate a focused system prompt for each agent role.
    static func systemPromptForRole(_ role: TaskDecomposer.AgentRole) -> String {
        switch role {
        case .observer:
            return """
                You are the Observer agent. Your role is to read and describe the current \
                screen state, accessibility tree, and application context. Report facts only — \
                do not take actions or make suggestions. Focus on:
                - Current foreground application and window title
                - Key UI elements visible (buttons, text fields, labels)
                - Any relevant text content on screen
                - URL if in a browser
                """

        case .executor:
            return """
                You are the Executor agent. Your role is to perform UI actions and replay \
                procedures. You have access to AX tools (click, type, hotkey, scroll, wait, \
                focus_app, read_text) and procedure replay. Execute steps carefully: \
                1) ax_tree_query to understand current state, 2) perform action (click/type/hotkey), \
                3) ax_wait for UI to update, 4) ax_tree_query to verify result. \
                Report any unexpected UI state. Never interact with password fields.
                """

        case .memoryManager:
            return """
                You are the Memory Manager agent. Your role is to retrieve relevant information \
                from the user's memory stores: episodic memories (what happened), semantic \
                knowledge (learned facts and preferences), directives (active rules), and \
                procedures (learned workflows). Return concise, relevant results.
                """

        case .learningEngine:
            return """
                You are the Learning Engine agent. Your role is to record user demonstrations \
                and generalize them into reusable procedures. When learning mode is active, \
                capture each action with its context and intent. After recording, synthesize \
                a procedure template with parameters.
                """

        case .safetyMonitor:
            return """
                You are the Safety Monitor agent. Your role is to assess the risk of proposed \
                actions before they execute. Check for:
                - Secure text fields (passwords, credentials)
                - Destructive operations (delete, overwrite, send)
                - System-level changes (settings, permissions)
                - Financial or sensitive data handling
                Return a risk assessment with approval/denial recommendation.
                """

        case .general:
            // Falls back to the full AgentPromptBuilder system prompt
            return AgentPromptBuilder.systemPrompt
        }
    }

    // MARK: - Relevance Filtering

    /// Determine if a prior result is relevant for a given role.
    private static func isResultRelevant(
        _ result: SubTaskResult,
        forRole role: TaskDecomposer.AgentRole
    ) -> Bool {
        switch role {
        case .observer:
            // Observer doesn't need prior results (it reads live state)
            return false
        case .executor:
            // Executor needs memory results (procedures) and safety verdicts
            return result.role == .memoryManager || result.role == .safetyMonitor || result.role == .observer
        case .memoryManager:
            // Memory manager is usually first; rarely needs prior results
            return result.role == .observer
        case .learningEngine:
            // Learning engine needs observer context
            return result.role == .observer
        case .safetyMonitor:
            // Safety monitor needs to know what will be executed
            return result.role == .memoryManager || result.role == .observer
        case .general:
            // General agent gets everything
            return true
        }
    }

    /// Whether a role benefits from the memory pack.
    private static func roleUsesMemoryPack(_ role: TaskDecomposer.AgentRole) -> Bool {
        switch role {
        case .general, .memoryManager, .executor:
            return true
        case .observer, .learningEngine, .safetyMonitor:
            return false
        }
    }

    // MARK: - Token Estimation

    /// Estimate token count from character count.
    /// Uses the conservative 4 chars/token ratio for English text.
    static func estimateTokens(from text: String) -> Int {
        max(text.count / 4, 1)
    }

    /// Check if assembled context fits within budget.
    static func fitsWithinBudget(
        context: AgentContext,
        budget: BudgetConfig
    ) -> Bool {
        context.estimatedTokens <= budget.totalTokenBudget
    }
}

// MARK: - Sub-Task Result

/// Result from executing a single sub-task.
struct SubTaskResult: Sendable, Equatable {
    /// The sub-task ID.
    let taskId: String
    /// Which agent role executed this.
    let role: TaskDecomposer.AgentRole
    /// The output text from the agent.
    let output: String
    /// Whether the sub-task completed successfully.
    let success: Bool
    /// Execution time in milliseconds.
    let durationMs: Double
    /// Error message if the sub-task failed.
    let error: String?

    init(
        taskId: String,
        role: TaskDecomposer.AgentRole,
        output: String,
        success: Bool = true,
        durationMs: Double = 0,
        error: String? = nil
    ) {
        self.taskId = taskId
        self.role = role
        self.output = output
        self.success = success
        self.durationMs = durationMs
        self.error = error
    }
}
