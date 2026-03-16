import XCTest
@testable import Shadow

final class ContextBudgetManagerTests: XCTestCase {

    // MARK: - Budget Configuration

    /// Cloud budget has expected values.
    func testCloudBudget() {
        let budget = ContextBudgetManager.cloudBudget
        XCTAssertEqual(budget.totalTokenBudget, 128_000)
        XCTAssertEqual(budget.systemPromptBudget, 2_000)
        XCTAssertEqual(budget.memoryPackBudget, 4_000)
        XCTAssertEqual(budget.conversationBudget, 122_000)
        XCTAssertEqual(budget.maxSubAgentContextChars, 32_000)
    }

    /// Local large budget has expected values.
    func testLocalLargeBudget() {
        let budget = ContextBudgetManager.localLargeBudget
        XCTAssertEqual(budget.totalTokenBudget, 32_000)
        XCTAssertEqual(budget.systemPromptBudget, 1_500)
        XCTAssertEqual(budget.memoryPackBudget, 2_000)
        XCTAssertEqual(budget.conversationBudget, 28_500)
    }

    /// Local small budget has expected values.
    func testLocalSmallBudget() {
        let budget = ContextBudgetManager.localSmallBudget
        XCTAssertEqual(budget.totalTokenBudget, 16_000)
        XCTAssertEqual(budget.conversationBudget, 14_000)
    }

    /// Conversation budget is derived correctly.
    func testConversationBudgetDerivation() {
        let budget = ContextBudgetManager.BudgetConfig(
            totalTokenBudget: 10_000,
            systemPromptBudget: 1_000,
            memoryPackBudget: 2_000,
            maxSubAgentContextChars: 5_000
        )
        XCTAssertEqual(budget.conversationBudget, 7_000)
    }

    // MARK: - Context Assembly

    /// Build context for observer role.
    func testBuildContextObserver() {
        let context = ContextBudgetManager.buildContext(
            role: .observer,
            query: "What's on my screen?"
        )
        XCTAssertEqual(context.role, .observer)
        XCTAssertTrue(context.systemPrompt.contains("Observer"))
        XCTAssertGreaterThan(context.estimatedTokens, 0)
    }

    /// Build context for executor role.
    func testBuildContextExecutor() {
        let context = ContextBudgetManager.buildContext(
            role: .executor,
            query: "Click the submit button"
        )
        XCTAssertEqual(context.role, .executor)
        XCTAssertTrue(context.systemPrompt.contains("Executor"))
    }

    /// Build context for memory manager role.
    func testBuildContextMemoryManager() {
        let context = ContextBudgetManager.buildContext(
            role: .memoryManager,
            query: "Find my preferences"
        )
        XCTAssertEqual(context.role, .memoryManager)
        XCTAssertTrue(context.systemPrompt.contains("Memory Manager"))
    }

    /// Build context for safety monitor role.
    func testBuildContextSafetyMonitor() {
        let context = ContextBudgetManager.buildContext(
            role: .safetyMonitor,
            query: "Delete all files"
        )
        XCTAssertEqual(context.role, .safetyMonitor)
        XCTAssertTrue(context.systemPrompt.contains("Safety Monitor"))
    }

    /// Build context for learning engine role.
    func testBuildContextLearningEngine() {
        let context = ContextBudgetManager.buildContext(
            role: .learningEngine,
            query: "Watch me do this"
        )
        XCTAssertEqual(context.role, .learningEngine)
        XCTAssertTrue(context.systemPrompt.contains("Learning Engine"))
    }

    /// Build context for general role uses full system prompt.
    func testBuildContextGeneral() {
        let context = ContextBudgetManager.buildContext(
            role: .general,
            query: "What was I doing at 2pm?"
        )
        XCTAssertEqual(context.role, .general)
        XCTAssertTrue(context.systemPrompt.contains("Shadow"))
    }

    /// Prior results are injected when relevant.
    func testPriorResultsInjected() {
        let priorResults = [
            SubTaskResult(taskId: "t1", role: .observer, output: "Screen shows VS Code with main.swift"),
        ]
        let context = ContextBudgetManager.buildContext(
            role: .general,
            query: "What am I working on?",
            priorResults: priorResults
        )
        // General role gets all prior results
        XCTAssertTrue(context.injectedContext.contains("VS Code"))
    }

    /// Observer does not receive prior results.
    func testObserverNoPriorResults() {
        let priorResults = [
            SubTaskResult(taskId: "t1", role: .memoryManager, output: "Found procedure: expense report"),
        ]
        let context = ContextBudgetManager.buildContext(
            role: .observer,
            query: "Capture screen",
            priorResults: priorResults
        )
        XCTAssertTrue(context.injectedContext.isEmpty)
    }

    /// Executor receives memory and safety results.
    func testExecutorGetsPriorResults() {
        let priorResults = [
            SubTaskResult(taskId: "t1", role: .memoryManager, output: "Procedure found: file expense"),
            SubTaskResult(taskId: "t2", role: .safetyMonitor, output: "Risk: low, approved"),
            SubTaskResult(taskId: "t3", role: .learningEngine, output: "Not relevant"),
        ]
        let context = ContextBudgetManager.buildContext(
            role: .executor,
            query: "Execute procedure",
            priorResults: priorResults
        )
        XCTAssertTrue(context.injectedContext.contains("Procedure found"))
        XCTAssertTrue(context.injectedContext.contains("Risk: low"))
        XCTAssertFalse(context.injectedContext.contains("Not relevant"))
    }

    /// Memory pack is injected for roles that use it.
    func testMemoryPackInjected() {
        let context = ContextBudgetManager.buildContext(
            role: .general,
            query: "test",
            memoryPack: "User prefers VS Code. Uses dark theme."
        )
        XCTAssertTrue(context.injectedContext.contains("VS Code"))
        XCTAssertTrue(context.injectedContext.contains("memory_context"))
    }

    /// Memory pack is NOT injected for observer.
    func testMemoryPackNotForObserver() {
        let context = ContextBudgetManager.buildContext(
            role: .observer,
            query: "test",
            memoryPack: "User prefers VS Code"
        )
        XCTAssertFalse(context.injectedContext.contains("VS Code"))
    }

    // MARK: - Token Estimation

    /// estimateTokens works with known string.
    func testEstimateTokens() {
        let tokens = ContextBudgetManager.estimateTokens(from: "Hello, this is a test string of about forty characters.")
        XCTAssertGreaterThan(tokens, 10)
        XCTAssertLessThan(tokens, 20)
    }

    /// estimateTokens returns at least 1.
    func testEstimateTokensMinimum() {
        let tokens = ContextBudgetManager.estimateTokens(from: "ab")
        XCTAssertGreaterThanOrEqual(tokens, 1)
    }

    // MARK: - Budget Fit

    /// fitsWithinBudget returns true for small context.
    func testFitsWithinBudget() {
        let context = ContextBudgetManager.AgentContext(
            role: .observer,
            systemPrompt: "Short prompt",
            injectedContext: "",
            estimatedTokens: 100
        )
        XCTAssertTrue(ContextBudgetManager.fitsWithinBudget(
            context: context,
            budget: ContextBudgetManager.cloudBudget
        ))
    }

    /// fitsWithinBudget returns false for oversized context.
    func testDoesNotFitBudget() {
        let context = ContextBudgetManager.AgentContext(
            role: .general,
            systemPrompt: "Large prompt",
            injectedContext: "",
            estimatedTokens: 200_000
        )
        XCTAssertFalse(ContextBudgetManager.fitsWithinBudget(
            context: context,
            budget: ContextBudgetManager.cloudBudget
        ))
    }

    // MARK: - Role System Prompts

    /// Each role has a distinct system prompt.
    func testRoleSystemPromptsUnique() {
        var prompts: Set<String> = []
        for role in TaskDecomposer.AgentRole.allCases {
            let prompt = ContextBudgetManager.systemPromptForRole(role)
            XCTAssertFalse(prompts.contains(prompt), "Duplicate prompt for role: \(role.rawValue)")
            prompts.insert(prompt)
        }
    }

    /// Role prompts are non-empty.
    func testRolePromptsNonEmpty() {
        for role in TaskDecomposer.AgentRole.allCases {
            let prompt = ContextBudgetManager.systemPromptForRole(role)
            XCTAssertGreaterThan(prompt.count, 50, "Prompt too short for role: \(role.rawValue)")
        }
    }

    // MARK: - SubTaskResult

    /// SubTaskResult captures all fields.
    func testSubTaskResult() {
        let result = SubTaskResult(
            taskId: "t1",
            role: .observer,
            output: "Screen shows Safari",
            success: true,
            durationMs: 150,
            error: nil
        )
        XCTAssertEqual(result.taskId, "t1")
        XCTAssertEqual(result.role, .observer)
        XCTAssertEqual(result.output, "Screen shows Safari")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.durationMs, 150)
        XCTAssertNil(result.error)
    }

    /// SubTaskResult with error.
    func testSubTaskResultError() {
        let result = SubTaskResult(
            taskId: "t1",
            role: .executor,
            output: "",
            success: false,
            durationMs: 50,
            error: "Permission denied"
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Permission denied")
    }

    /// SubTaskResult defaults.
    func testSubTaskResultDefaults() {
        let result = SubTaskResult(
            taskId: "t1",
            role: .general,
            output: "test"
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.durationMs, 0)
        XCTAssertNil(result.error)
    }

    /// SubTaskResult is Equatable.
    func testSubTaskResultEquatable() {
        let r1 = SubTaskResult(taskId: "t1", role: .observer, output: "test")
        let r2 = SubTaskResult(taskId: "t1", role: .observer, output: "test")
        XCTAssertEqual(r1, r2)
    }
}
