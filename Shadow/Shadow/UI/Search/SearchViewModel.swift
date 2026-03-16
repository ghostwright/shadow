import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SearchViewModel")

/// View model for the search overlay. Manages query debouncing, search execution,
/// result state, and keyboard navigation.
@Observable
@MainActor
final class SearchViewModel {
    var query: String = "" {
        didSet {
            querySubject.send(query)
        }
    }

    var results: [SearchResult] = []
    var selectedIndex: Int = 0
    var isSearching: Bool = false
    var searchLatencyMs: Double = 0

    /// Current command execution state. Observed by SearchOverlayView.
    var commandState: CommandState = .idle {
        didSet {
            onCommandStateChanged?(commandState)
        }
    }

    /// The currently selected search result, if any.
    var selectedResult: SearchResult? {
        selectedIndex < results.count ? results[selectedIndex] : nil
    }

    /// Callbacks wired by SearchPanelController.
    var onDismiss: (() -> Void)?
    var onOpenTimeline: ((UInt64, UInt32?) -> Void)?
    var onCommandStateChanged: ((CommandState) -> Void)?

    /// Reference to the summary job queue, injected by SearchPanelController.
    var summaryJobQueue: SummaryJobQueue?

    /// Mutable state for an in-flight agent run. Observed by AgentStreamingView.
    var agentStreamState: AgentStreamState?

    /// Injectable agent run function. When non-nil, ⌘↩ uses the agent path.
    /// Tests can replace this to inject mock streams.
    var agentRunFunction: (@Sendable (AgentRunRequest) -> AsyncStream<AgentRunEvent>)?

    private let querySubject = PassthroughSubject<String, Never>()
    /// Injectable summarization function. Default calls SummaryCoordinator.
    /// Tests can replace this to simulate delayed/failed/cancelled behavior.
    var summarizeFunction: @Sendable (SummaryJobQueue) async throws -> SummarizationResult = { queue in
        try await SummaryCoordinator.summarizeLatestMeeting(queue: queue)
    }

    private var cancellable: AnyCancellable?
    private var commandTask: Task<Void, Never>?
    /// Token identifying the active command run. Stale runs compare against this
    /// before writing state, preventing cancelled/old runs from mutating the UI.
    private var activeRunID = UUID()

    /// CLIP text encoder for query→vector encoding. Nil when model not available.
    private let clipEncoder: CLIPEncoder?

    /// LRU cache for query embeddings.
    private let queryCache: QueryEmbeddingCache?

    init() {
        // Attempt to load CLIP encoder for visual query support
        let encoder = CLIPEncoder()
        self.clipEncoder = encoder
        self.queryCache = encoder.map { QueryEmbeddingCache(capacity: 128, modelId: $0.modelId) }

        if encoder != nil {
            logger.info("Search: CLIP text encoder available — visual queries enabled")
        }

        // Debounce search queries by 150ms to avoid hammering the index
        cancellable = querySubject
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                Task { @MainActor in
                    self?.executeSearch(query)
                }
            }
    }

    func clear() {
        AudioPlayer.shared.stop()
        cancelCommand()
        query = ""
        results = []
        selectedIndex = 0
        isSearching = false
        agentStreamState = nil
    }

    // MARK: - Keyboard Navigation

    func moveSelectionUp() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        }
    }

    func moveSelectionDown() {
        if selectedIndex < results.count - 1 {
            selectedIndex += 1
        }
    }

    func confirmSelection() {
        guard case .idle = commandState else { return }
        guard selectedIndex < results.count else { return }
        AudioPlayer.shared.stop()
        let result = results[selectedIndex]
        openInTimeline(result)
    }

    func openInTimeline(_ result: SearchResult) {
        let displayID: UInt32? = result.displayId
        onOpenTimeline?(result.ts, displayID)

        DiagnosticsStore.shared.increment("search_result_opened_total")
    }

    // MARK: - Query Vector Encoding

    /// Encode a text query into a CLIP embedding vector.
    /// Uses LRU cache for repeated queries. Returns empty array when encoder unavailable.
    private func encodeQueryVector(_ query: String) -> [Float] {
        guard let encoder = clipEncoder, let cache = queryCache else {
            return []
        }

        DiagnosticsStore.shared.increment("vector_query_encode_attempt_total")

        // Check cache first
        if let cached = cache.get(query: query) {
            return cached
        }

        // Encode on current thread (text encoding is fast, ~1-5ms)
        guard let vector = encoder.embedText(query) else {
            DiagnosticsStore.shared.increment("vector_query_encode_fail_total")
            return []
        }

        cache.put(query: query, vector: vector)
        DiagnosticsStore.shared.increment("vector_query_encode_success_total")
        return vector
    }

    // MARK: - Command Execution

    /// Execute a command. Routes to agent path (when agentRunFunction is set)
    /// or meeting-summary path (when only summaryJobQueue is available).
    /// Guards: idle state, non-empty query.
    func executeCommand() {
        guard case .idle = commandState else { return }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if agentRunFunction != nil {
            executeAgentCommand()
        } else if summaryJobQueue != nil {
            executeSummaryCommand()
        } else {
            commandState = .error(.queueNotReady)
            DiagnosticsStore.shared.increment("command_execute_no_queue_total")
            logger.warning("Command triggered but no agent or queue available")
        }
    }

    /// Cancel any running command and return to idle state.
    /// Invalidates the active run token so in-flight writes are blocked.
    func cancelCommand() {
        activeRunID = UUID()
        commandTask?.cancel()
        commandTask = nil
        commandState = .idle
        agentStreamState = nil

        // Notify focus manager that agent execution has ended
        AgentFocusManager.shared.agentRunEnded()
    }

    /// Dismiss the command result/error and return to idle state.
    func dismissCommandResult() {
        commandState = .idle
        agentStreamState = nil
    }

    // MARK: - Agent Execution

    /// Execute the agent command. Streams events from the runtime into agentStreamState.
    /// Each run gets a unique token; stale runs cannot mutate state.
    ///
    /// Notifies `AgentFocusManager` when the run starts and ends so that:
    /// - The search panel suppresses auto-dismiss during execution
    /// - AX tools target the correct app (not Shadow)
    private func executeAgentCommand() {
        guard let runFunction = agentRunFunction else { return }

        let runID = UUID()
        activeRunID = runID

        let request = AgentRunRequest(
            task: query.trimmingCharacters(in: .whitespacesAndNewlines),
            config: AgentRunConfig()
        )

        agentStreamState = AgentStreamState(task: request.task)
        commandState = .agentStreaming
        DiagnosticsStore.shared.increment("agent_command_execute_total")

        // Notify focus manager that an agent run is active
        AgentFocusManager.shared.agentRunStarted()

        commandTask = Task { @MainActor in
            defer {
                // Always notify focus manager when run ends, regardless of outcome
                AgentFocusManager.shared.agentRunEnded()
            }

            let stream = runFunction(request)
            var receivedTerminalEvent = false

            for await event in stream {
                guard runID == self.activeRunID else { break }
                // Track terminal events before reducing (reducer may early-return)
                switch event {
                case .finalAnswer, .runFailed, .runCancelled:
                    receivedTerminalEvent = true
                default:
                    break
                }
                self.reduceAgentEvent(event, runID: runID)
            }

            // If stream ended without a terminal event and this run is still active,
            // transition to a safe error state so the UI doesn't hang in .agentStreaming.
            if runID == self.activeRunID {
                if !receivedTerminalEvent {
                    self.agentStreamState = nil
                    self.commandState = .error(.agentError("Agent stream ended unexpectedly. Please try again."))
                    DiagnosticsStore.shared.increment("agent_stream_unexpected_end_total")
                    logger.warning("Agent stream ended without terminal event")
                }
                self.commandTask = nil
            }
        }
    }

    /// Reduce an agent event into the live stream state.
    /// Runs on MainActor (inherited from Task). Stale-run check prevents post-cancel mutation.
    private func reduceAgentEvent(_ event: AgentRunEvent, runID: UUID) {
        guard runID == activeRunID else { return }
        guard var state = agentStreamState else { return }

        switch event {
        case .runStarted(let task):
            state.task = task
            state.status = .starting

        case .intentClassified(let intent, let confidence, let method):
            state.classifiedIntent = intent
            state.classifiedConfidence = confidence
            state.classificationMethod = method

        case .llmRequestStarted(let step):
            state.currentStep = step

        case .llmDelta(let text):
            state.liveAnswer += text
            state.status = .streaming

        case .toolCallStarted(let name, let step):
            state.toolTimeline.append(
                ToolActivityEntry(name: name, step: step, status: .running)
            )
            state.status = .toolRunning

            // Forward progress to the background status indicator if active
            let bgMgr = BackgroundTaskManager.shared
            if bgMgr.isBackgroundTaskActive {
                bgMgr.updateProgress(currentTool: name, step: step, totalSteps: 0)
            }

        case .toolCallCompleted(let name, let ms, _):
            if let idx = state.toolTimeline.lastIndex(where: {
                $0.name == name && $0.status == .running
            }) {
                state.toolTimeline[idx].status = .completed(durationMs: ms)
            }
            state.status = .streaming

        case .toolCallFailed(let name, let error):
            if let idx = state.toolTimeline.lastIndex(where: {
                $0.name == name && $0.status == .running
            }) {
                state.toolTimeline[idx].status = .failed(error: error)
            }
            // Non-fatal — don't change overall status

        case .finalAnswer(let result):
            state.evidence = result.evidence
            state.metrics = result.metrics
            state.liveAnswer = result.answer
            state.status = .complete
            agentStreamState = state
            commandState = .agentResult

            // Restore focus to the origin app ONLY if the agent actually navigated
            // away from Shadow to interact with another app (i.e., entered background mode).
            // For simple chat questions where the agent never left the overlay, restoring
            // origin would dismiss the panel before the user can read the answer.
            if BackgroundTaskManager.shared.isBackgroundTaskActive {
                AgentFocusManager.shared.restoreOrigin()
            }

            // If running in background, show completion in the status indicator
            let bgComplete = BackgroundTaskManager.shared
            if bgComplete.isBackgroundTaskActive {
                let summary = String(result.answer.prefix(80))
                bgComplete.complete(summary: summary.isEmpty ? "Task complete" : summary)
            }
            return

        case .runFailed(let error):
            commandState = .error(.agentError(error.displayMessage))
            agentStreamState = nil

            // Restore focus to origin even on failure -- but only if the agent
            // actually navigated away. Same guard as the success path.
            if BackgroundTaskManager.shared.isBackgroundTaskActive {
                AgentFocusManager.shared.restoreOrigin()
            }

            // If running in background, show failure in the status indicator
            let bgFail = BackgroundTaskManager.shared
            if bgFail.isBackgroundTaskActive {
                bgFail.fail(error: error.displayMessage)
            }
            return

        case .runCancelled:
            // If running in background, exit background mode
            let bgCancel = BackgroundTaskManager.shared
            if bgCancel.isBackgroundTaskActive {
                bgCancel.exitBackground()
            }
            // Already handled by cancelCommand()
            return
        }

        agentStreamState = state
    }

    // MARK: - Meeting Summary Execution

    /// Execute the meeting summarization command (legacy path).
    /// Cancellation semantics: `cancelCommand()` invalidates the run token and cancels
    /// the command task (cooperative). The underlying `SummaryJobQueue` work is NOT
    /// cancelled — it runs to completion and the result is persisted to the store but
    /// silently discarded by the UI.
    private func executeSummaryCommand() {
        guard let queue = summaryJobQueue else {
            commandState = .error(.queueNotReady)
            DiagnosticsStore.shared.increment("command_execute_no_queue_total")
            logger.warning("Command triggered but summaryJobQueue is nil")
            return
        }

        let runID = UUID()
        activeRunID = runID

        commandState = .running(stage: "Resolving meeting\u{2026}")
        DiagnosticsStore.shared.increment("command_execute_total")

        let myStageTask = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard runID == self.activeRunID else { return }
            self.commandState = .running(stage: "Assembling transcript\u{2026}")
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard runID == self.activeRunID else { return }
            self.commandState = .running(stage: "Generating summary\u{2026}")
        }

        commandTask = Task {
            defer { myStageTask.cancel() }

            do {
                let result = try await self.summarizeFunction(queue)
                guard runID == self.activeRunID else { return }

                switch result {
                case .success(let summary):
                    self.commandState = .result(summary)
                    DiagnosticsStore.shared.increment("command_success_total")
                    logger.info("Command completed: \(summary.title)")

                case .noMeetingFound:
                    self.commandState = .error(.noMeetingFound)
                    DiagnosticsStore.shared.increment("command_no_meeting_total")
                    logger.info("Command: no meeting found")

                case .disambiguation(let candidates):
                    self.commandState = .error(.multipleMeetingsFound)
                    logger.info("Command: disambiguation with \(candidates.count) candidates")
                }
            } catch is CancellationError {
                logger.info("Command execution cancelled by user")
            } catch {
                guard runID == self.activeRunID else { return }
                self.commandState = .error(.providerError(error.localizedDescription))
                DiagnosticsStore.shared.increment("command_execute_fail_total")
                logger.error("Command execution failed: \(error, privacy: .public)")
            }

            if runID == self.activeRunID {
                self.commandTask = nil
            }
        }
    }

    // MARK: - Search Execution

    private func executeSearch(_ queryText: String) {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            selectedIndex = 0
            isSearching = false
            return
        }

        isSearching = true
        let startTime = CFAbsoluteTimeGetCurrent()

        DiagnosticsStore.shared.increment("search_queries_total")

        // Encode query vector on main thread (fast, ~1-5ms with cache)
        let queryVector = encodeQueryVector(trimmed)

        Task.detached(priority: .userInitiated) {
            do {
                // Index any pending events before searching
                let _ = try indexRecentEvents()

                // Hybrid search: text + vector. Empty queryVector falls back to text-only.
                let searchResults = try searchHybrid(query: trimmed, queryVector: queryVector, limit: 50)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

                await MainActor.run {
                    self.results = searchResults
                    self.selectedIndex = 0
                    self.isSearching = false
                    self.searchLatencyMs = elapsed

                    DiagnosticsStore.shared.recordLatency("search_query_ms", ms: elapsed)
                    DiagnosticsStore.shared.increment("search_results_returned_total", by: Int64(searchResults.count))
                }
            } catch {
                logger.error("Search failed: \(error, privacy: .public)")
                await MainActor.run {
                    self.results = []
                    self.isSearching = false

                    DiagnosticsStore.shared.increment("search_query_fail_total")
                    DiagnosticsStore.shared.postWarning(
                        severity: .warning,
                        subsystem: "Search",
                        code: "SEARCH_QUERY_FAILED",
                        message: "Search query failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
}
