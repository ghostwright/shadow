import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProactiveLiveAnalyzer")

/// Tool-augmented proactive analyzer with two tiers: fast tick (live context) and deep tick (patterns).
///
/// Stateless enum (same pattern as `AgentRuntime`, `ContextSynthesizer`).
///
/// Fast tick (every ~10 min): Gathers current app/window/screenshot, uses tools to search
/// for relevant context, produces 0-1 push_now suggestions.
///
/// Deep tick (every ~30 min): Broader analysis with episodes, daily open loops, and tools.
/// Produces 0-3 inbox_only suggestions.
///
/// Evidence flows through the same `SuggestionEvidence` type used by ProactiveInboxView
/// for deep-links. Scoring via `ProactivePolicyEngine`. Persistence via `ProactiveStore`.
enum ProactiveLiveAnalyzer {

    // MARK: - Types

    /// Snapshot of the user's current activity, assembled by the heartbeat from timeline queries.
    struct LiveContextSnapshot: Sendable {
        let currentApp: String
        let windowTitle: String
        let url: String?
        let displayId: UInt32?
        /// How long the user has been in the current app (seconds).
        let activeSeconds: Int
        /// Recent app transitions (last 10 minutes), newest first.
        let recentApps: [RecentAppEntry]
    }

    /// A single entry in the recent app activity sequence.
    struct RecentAppEntry: Sendable {
        let app: String
        let title: String
        let ts: UInt64
    }

    /// Tracks the last suggestion pushed to avoid repetition.
    struct LastPushState: Sendable {
        let title: String
        let app: String?
        let timestamp: Date
    }

    // MARK: - Budget Constants

    /// Fast tick: focused on immediate context, generous tool budget.
    private static let fastMaxSteps = 5
    private static let fastMaxToolCalls = 10
    private static let fastTimeoutSeconds: Double = 60

    /// Deep tick: broader analysis with full exploration budget.
    private static let deepMaxSteps = 8
    private static let deepMaxToolCalls = 15
    private static let deepTimeoutSeconds: Double = 90

    // MARK: - Fast Tick

    /// Analyze the user's current activity and produce 0-1 push-worthy suggestions.
    ///
    /// Pipeline: assemble prompt with live context + screenshot → multi-turn LLM with tools →
    /// parse suggestions → extract evidence → score via PolicyEngine → persist.
    static func fastTick(
        toolRegistry: AgentToolRegistry,
        proactiveStore: ProactiveStore,
        trustTuner: TrustTuner,
        generate: @escaping LLMGenerateFunction,
        liveContext: LiveContextSnapshot,
        screenshot: ImageData?,
        lastPushState: LastPushState?
    ) async throws -> [ProactiveSuggestion] {
        let startTime = CFAbsoluteTimeGetCurrent()

        let systemPrompt = buildFastTickPrompt(liveContext: liveContext, lastPushState: lastPushState)

        // Build initial user message — include screenshot if available
        var userContent: [LLMMessageContent] = [.text("Analyze my current context and decide if there's anything useful to surface right now.")]
        if let img = screenshot {
            userContent.append(.image(mediaType: img.mediaType, base64Data: img.base64Data))
        }

        let initialMessages = [LLMMessage(role: "user", content: userContent)]

        let (answer, toolEvidence) = try await runToolLoop(
            systemPrompt: systemPrompt,
            initialMessages: initialMessages,
            toolSpecs: toolRegistry.toolSpecs,
            generate: generate,
            registry: toolRegistry,
            maxSteps: fastMaxSteps,
            maxToolCalls: fastMaxToolCalls,
            timeoutSeconds: fastTimeoutSeconds
        )

        let suggestions = processCandidates(
            answer: answer,
            toolEvidence: toolEvidence,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            maxSuggestions: 1
        )

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Fast tick: \(suggestions.count) suggestion(s) in \(String(format: "%.0f", elapsed))ms")

        return suggestions
    }

    // MARK: - Deep Tick

    /// Analyze broader work patterns and produce 0-3 inbox suggestions.
    ///
    /// Includes episode summaries and daily open loops alongside live context for richer analysis.
    static func deepTick(
        toolRegistry: AgentToolRegistry,
        contextStore: ContextStore,
        proactiveStore: ProactiveStore,
        trustTuner: TrustTuner,
        generate: @escaping LLMGenerateFunction,
        liveContext: LiveContextSnapshot
    ) async throws -> [ProactiveSuggestion] {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Gather broader context
        let episodes = Array(contextStore.listEpisodes().prefix(6))
        let dailies = Array(contextStore.listDailies().prefix(2))

        let systemPrompt = buildDeepTickPrompt(
            liveContext: liveContext,
            episodes: episodes,
            dailies: dailies
        )

        let initialMessages = [
            LLMMessage(role: "user", content: [
                .text("Analyze my broader work patterns and surface any useful reminders or insights for my inbox.")
            ])
        ]

        let (answer, toolEvidence) = try await runToolLoop(
            systemPrompt: systemPrompt,
            initialMessages: initialMessages,
            toolSpecs: toolRegistry.toolSpecs,
            generate: generate,
            registry: toolRegistry,
            maxSteps: deepMaxSteps,
            maxToolCalls: deepMaxToolCalls,
            timeoutSeconds: deepTimeoutSeconds
        )

        let suggestions = processCandidates(
            answer: answer,
            toolEvidence: toolEvidence,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            maxSuggestions: 3
        )

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Deep tick: \(suggestions.count) suggestion(s) in \(String(format: "%.0f", elapsed))ms")

        return suggestions
    }

    // MARK: - Multi-Turn Tool Loop

    /// Execute a multi-turn LLM loop with tool calling.
    ///
    /// Simpler than AgentRuntime — no streaming, no events, no UI concerns.
    /// Returns the final answer text and evidence extracted from tool outputs.
    private static func runToolLoop(
        systemPrompt: String,
        initialMessages: [LLMMessage],
        toolSpecs: [ToolSpec],
        generate: @escaping LLMGenerateFunction,
        registry: AgentToolRegistry,
        maxSteps: Int,
        maxToolCalls: Int,
        timeoutSeconds: Double
    ) async throws -> (answer: String, evidence: [SuggestionEvidence]) {
        let startTime = CFAbsoluteTimeGetCurrent()
        var messages = initialMessages
        var toolCallCount = 0
        var allEvidence: [SuggestionEvidence] = []
        var lastText = ""

        for step in 0..<maxSteps {
            // Check timeout
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed > timeoutSeconds {
                logger.debug("Tool loop timed out at step \(step)")
                break
            }

            // Check cancellation
            if Task.isCancelled { break }

            let request = LLMRequest(
                systemPrompt: systemPrompt,
                userPrompt: "",
                tools: toolSpecs,
                maxTokens: 2048,
                temperature: 0.3,
                responseFormat: .text,
                messages: messages
            )

            let response = try await generate(request)

            if !response.content.isEmpty {
                lastText = response.content
            }

            // No tool calls → done
            if response.toolCalls.isEmpty {
                return (lastText, allEvidence)
            }

            // Build assistant message with tool_use blocks
            var assistantContent: [LLMMessageContent] = []
            if !response.content.isEmpty {
                assistantContent.append(.text(response.content))
            }
            for tc in response.toolCalls {
                assistantContent.append(.toolUse(id: tc.id, name: tc.name, input: tc.arguments))
            }
            messages.append(LLMMessage(role: "assistant", content: assistantContent))

            // Execute tool calls — must produce a tool_result for EVERY tool_use
            // to satisfy the Anthropic API contract (tool_use/tool_result pairing).
            var toolResultContents: [LLMMessageContent] = []
            var budgetExhausted = false

            for call in response.toolCalls {
                if toolCallCount >= maxToolCalls || Task.isCancelled {
                    // Budget or cancellation — still must provide a result for this tool_use
                    toolResultContents.append(.toolResult(
                        toolUseId: call.id, content: "Tool call skipped: budget exhausted", isError: true))
                    budgetExhausted = true
                    continue
                }

                toolCallCount += 1
                let result = await registry.execute(call)

                // Extract evidence from tool output
                let agentEvidence = AgentRuntime.extractEvidence(from: result.content, toolName: call.name)
                for item in agentEvidence {
                    allEvidence.append(SuggestionEvidence(
                        timestamp: item.timestamp,
                        app: item.app,
                        sourceKind: item.sourceKind,
                        displayId: item.displayId,
                        url: item.url,
                        snippet: item.snippet
                    ))
                }

                toolResultContents.append(.toolResult(
                    toolUseId: call.id, content: result.content, isError: result.isError))

                // Append image blocks if present
                for img in result.images {
                    toolResultContents.append(.image(mediaType: img.mediaType, base64Data: img.base64Data))
                }
            }

            // Inject budget warning when close to limits so the LLM wraps up
            let remainingCalls = maxToolCalls - toolCallCount
            let remainingSteps = maxSteps - step - 1
            if !budgetExhausted && (remainingCalls <= 2 || remainingSteps <= 1) {
                toolResultContents.append(.text(
                    "[SYSTEM: You have \(remainingCalls) tool call(s) and \(remainingSteps) turn(s) remaining. " +
                    "Produce your final JSON output now based on what you've found so far.]"
                ))
            }

            messages.append(LLMMessage(role: "user", content: toolResultContents))

            // If budget exhausted, stop the loop — next iteration would waste a call
            if budgetExhausted { break }
        }

        // Budget exhausted — use last text
        return (lastText, allEvidence)
    }

    // MARK: - Candidate Processing

    /// Parse LLM answer, extract candidates, score via PolicyEngine, persist.
    private static func processCandidates(
        answer: String,
        toolEvidence: [SuggestionEvidence],
        proactiveStore: ProactiveStore,
        trustTuner: TrustTuner,
        maxSuggestions: Int
    ) -> [ProactiveSuggestion] {
        let candidates = parseCandidates(from: answer, fallbackEvidence: toolEvidence)
        DiagnosticsStore.shared.increment("proactive_candidate_total", by: Int64(candidates.count))

        var persisted: [ProactiveSuggestion] = []

        for candidate in candidates.prefix(maxSuggestions) {
            // Hard gate: evidence must be non-empty
            if candidate.evidence.isEmpty {
                DiagnosticsStore.shared.increment("proactive_drop_total")
                continue
            }

            let policyInput = PolicyInput(
                suggestionType: candidate.type,
                confidence: candidate.confidence,
                evidenceQuality: evidenceQuality(candidate.evidence),
                noveltyScore: 0.7,
                interruptionCost: 0.0,
                preferenceAffinity: trustTuner.effectiveParameters().preferredSuggestionTypes[candidate.type] ?? 0.0
            )

            let policyOutput = ProactivePolicyEngine.evaluate(policyInput, tuner: trustTuner)

            let suggestion = ProactiveSuggestion(
                id: UUID(),
                createdAt: Date(),
                type: candidate.type,
                title: candidate.title,
                body: candidate.body,
                whyNow: candidate.whyNow,
                confidence: policyOutput.score,
                decision: policyOutput.decision,
                evidence: candidate.evidence,
                sourceRecordIds: candidate.sourceRecordIds,
                status: .active
            )

            switch policyOutput.decision {
            case .pushNow:
                proactiveStore.saveSuggestion(suggestion)
                persisted.append(suggestion)
                DiagnosticsStore.shared.increment("proactive_push_total")
                logger.info("Suggestion push_now: \(suggestion.title)")

            case .inboxOnly:
                proactiveStore.saveSuggestion(suggestion)
                persisted.append(suggestion)
                DiagnosticsStore.shared.increment("proactive_inbox_only_total")
                logger.info("Suggestion inbox_only: \(suggestion.title)")

            case .drop:
                DiagnosticsStore.shared.increment("proactive_drop_total")
                logger.debug("Suggestion dropped: \(suggestion.title) (\(String(format: "%.3f", policyOutput.score)))")
            }
        }

        return persisted
    }

    // MARK: - Parsing

    private struct Candidate {
        let type: SuggestionType
        let title: String
        let body: String
        let whyNow: String
        let confidence: Double
        let evidence: [SuggestionEvidence]
        let sourceRecordIds: [String]
    }

    private static func parseCandidates(
        from content: String,
        fallbackEvidence: [SuggestionEvidence]
    ) -> [Candidate] {
        let cleaned = cleanJSONContent(content)
        guard let data = cleaned.data(using: .utf8) else { return [] }

        // Expect {"suggestions": [...]}
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let suggestions = root["suggestions"] as? [[String: Any]] else {
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return arr.compactMap { parseSingleCandidate($0, fallbackEvidence: fallbackEvidence) }
            }
            return []
        }

        return suggestions.compactMap { parseSingleCandidate($0, fallbackEvidence: fallbackEvidence) }
    }

    private static func parseSingleCandidate(
        _ dict: [String: Any],
        fallbackEvidence: [SuggestionEvidence]
    ) -> Candidate? {
        guard let title = dict["title"] as? String, !title.isEmpty,
              let body = dict["body"] as? String, !body.isEmpty else {
            return nil
        }

        let typeStr = dict["type"] as? String ?? "followup"
        let type = SuggestionType(rawValue: typeStr) ?? .followup
        let whyNow = dict["whyNow"] as? String ?? ""
        let confidence = (dict["confidence"] as? Double) ?? 0.5

        // Parse evidence from LLM output
        let evidenceArray = dict["evidence"] as? [[String: Any]] ?? []
        var evidence: [SuggestionEvidence] = evidenceArray.compactMap { parseEvidence($0) }

        // If LLM didn't produce evidence, use evidence from tool outputs
        if evidence.isEmpty {
            evidence = Array(fallbackEvidence.prefix(5))
        }

        let sourceRecordIds = dict["sourceRecordIds"] as? [String] ?? []

        return Candidate(
            type: type,
            title: title,
            body: body,
            whyNow: whyNow,
            confidence: confidence,
            evidence: evidence,
            sourceRecordIds: sourceRecordIds
        )
    }

    private static func parseEvidence(_ dict: [String: Any]) -> SuggestionEvidence? {
        guard let tsNumber = dict["timestamp"] as? NSNumber,
              let timestamp = ContextSynthesizer.safeUInt64(tsNumber) else { return nil }
        let displayId: UInt32? = (dict["displayId"] as? NSNumber).flatMap { ContextSynthesizer.safeUInt32($0) }
        return SuggestionEvidence(
            timestamp: timestamp,
            app: dict["app"] as? String,
            sourceKind: dict["sourceKind"] as? String ?? "proactive",
            displayId: displayId,
            url: dict["url"] as? String,
            snippet: dict["snippet"] as? String ?? ""
        )
    }

    /// Compute evidence quality score [0, 1] based on richness.
    private static func evidenceQuality(_ evidence: [SuggestionEvidence]) -> Double {
        guard !evidence.isEmpty else { return 0 }
        let count = min(Double(evidence.count), 5.0)
        let hasApps = evidence.contains { $0.app != nil }
        let hasSnippets = evidence.contains { !$0.snippet.isEmpty }
        return min(1.0, (count / 5.0) * 0.5 + (hasApps ? 0.25 : 0) + (hasSnippets ? 0.25 : 0))
    }

    // MARK: - Prompt Builders

    private static func buildFastTickPrompt(
        liveContext: LiveContextSnapshot,
        lastPushState: LastPushState?
    ) -> String {
        var prompt = """
        You are a proactive assistant that sees the user's current activity and their full history \
        of screen recordings, transcripts, and app usage. Your job is to connect the user's PAST to \
        their PRESENT — surfacing things they don't currently have in front of them but would benefit \
        from knowing. Most of the time, there is nothing useful to say. That's fine. When there IS \
        something, make it specific, evidence-backed, and actionable.

        ## Current Context

        - App: \(liveContext.currentApp)
        - Window: \(liveContext.windowTitle)
        """

        if let url = liveContext.url {
            prompt += "\n- URL: \(url)"
        }

        prompt += "\n- Active for: \(liveContext.activeSeconds)s in this app"

        if !liveContext.recentApps.isEmpty {
            prompt += "\n- Recent activity (last 10 min):"
            for entry in liveContext.recentApps.prefix(10) {
                prompt += "\n  \(entry.app): \(entry.title)"
            }
        }

        if let last = lastPushState {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            prompt += "\n- Last suggestion shown: \"\(last.title)\" at \(formatter.string(from: last.timestamp))"
        }

        let now = Date()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = .current
        prompt += "\n- Current time: \(timeFormatter.string(from: now))"

        prompt += """


        ## Your Tools

        You have these tools to search the user's captured data. Use them to find specific, relevant context:

        - **search_hybrid(query, limit?)** — Search all captured data: app names, window titles, OCR text, \
        transcripts. This is your primary tool. Extract key terms from the window title or URL and search \
        for related past activity. Example: if the user is in "Kris (DM) - Slack", search for "Kris" to \
        find prior conversations, meetings, and context about that person.

        - **get_transcript_window(startUs, endUs, limit?)** — Get audio transcripts in a time range. \
        Entries marked (mic) are the USER's own voice — things they said. Entries marked (system) are \
        OTHER PARTICIPANTS — meeting attendees, call audio. Use this to find what was discussed in a \
        recent meeting or call, especially commitments the user made ("I'll do X") or requests from others.

        - **search_summaries(query, limit?)** — Search generated meeting summaries. Use when the current \
        context suggests a meeting topic — find action items, decisions, and follow-ups from past meetings.

        - **resolve_latest_meeting()** — Find the most recent meeting/call with transcript data. Use when \
        the user just came from a video call app (Zoom, Teams, etc.) to check if there are fresh action items.

        - **get_activity_sequence(startUs, endUs, limit?)** — Get chronological app transitions in a time \
        window. Use to understand what the user was doing before their current activity — useful for \
        detecting context switches or understanding workflow.

        - **get_day_summary(dateStr)** — Get today's app usage breakdown (which apps, how long). Use to \
        detect workload patterns: too many meetings, long coding sessions without breaks, excessive \
        context switching.

        - **get_timeline_context(timestampUs, windowMinutes?)** — Get detailed context around a specific \
        timestamp. Use to drill into a specific moment found via search.

        - **search_visual_memories(query, limit?)** — Search screen recordings by visual content (CLIP). \
        Use when you need to find something visual the user was looking at.

        - **inspect_screenshots(candidates)** — Extract and view actual screen frames at timestamps. Use \
        after search_visual_memories to examine specific moments visually.

        ## What Makes a Good Nudge

        A good nudge tells the user something they DON'T already know. It bridges their past to their \
        present — surfacing forgotten context, unfinished commitments, or related history that's relevant \
        to what they're doing right now.

        **The test:** would the user learn something new from this nudge? If the answer is no — if \
        you're just describing what's already on screen, narrating their current activity, or restating \
        something they just said — return empty instead. Never narrate the present. Always connect to \
        the past or offer something that adds value beyond what the user can already see.

        Good nudges fall into these categories:
        - **Forgotten commitments**: things the user said they'd do (found in mic transcripts) that \
        are relevant to their current context
        - **Related history**: past conversations, meetings, or work sessions involving the same \
        people, projects, or topics they're currently engaged with
        - **Unfinished threads**: prior interactions where something was left open or pending
        - **Helpful offers**: when the user is composing or reviewing something, offer to provide \
        related context or help improve it based on their history

        ## Strategy

        1. **Extract entities from the current context.** The window title and URL contain the most \
        actionable information — person names, project names, ticket IDs, URLs.
        2. **Search for those entities.** Use search_hybrid with the key terms to find related past \
        activity involving the same people, projects, or topics.
        3. **Look for unfinished business.** If search results show meetings, action items, or the user's \
        own commitments (mic transcripts where they said "I'll..."), that's a suggestion.
        4. **Check for recency.** If the user just came from a meeting app, use resolve_latest_meeting to \
        find fresh action items that need follow-up.
        5. **Offer to help when relevant.** If the user is composing or reviewing something and you found \
        related context from their past, offer to provide a summary or help improve it.
        6. **Say nothing if nothing is relevant.** Most of the time, the user is just working normally. \
        Don't force a suggestion. Return empty if nothing is genuinely useful.

        ## Tool Budget — Be Efficient

        You have a limited tool call budget. Being smart about your calls is critical:

        - **Start with ONE targeted search_hybrid call** using the most specific entity from the current \
        context (a person name, project name, or ticket ID). If it returns nothing relevant, STOP — \
        return {"suggestions": []} immediately. Don't try more searches hoping for results.
        - **Typical tick: 1-3 tool calls.** Most ticks need just 1 search to determine nothing is relevant. \
        Only make follow-up calls when the first result reveals something worth digging into.
        - **Never search speculatively.** Don't call tools "just in case". Each call should have a clear \
        hypothesis: "I think there might be meeting notes about X because the user is now in context Y."
        - **get_day_summary and get_activity_sequence are expensive — avoid in fast tick.** Save these for \
        the deep tick which focuses on patterns. The fast tick should focus on the immediate context.
        - **If your first search finds nothing, that IS the answer.** Return empty. Don't retry with \
        different queries or try other tools hoping something sticks.
        - **Use parallel tool calls when appropriate.** If you need to search for two different entities, \
        request both tool calls in the same turn — they'll execute simultaneously. This is faster and \
        counts as fewer turns (though each still counts against your tool call limit).
        - **Always reserve your last turn for producing the final JSON output.** Don't use your entire \
        budget on tool calls and leave nothing for the answer.

        ## Rules

        - Generate 0-1 suggestions. Prefer saying nothing over weak suggestions.
        - Only suggest something if it's genuinely actionable RIGHT NOW for what the user is doing.
        - Evidence must reference real timestamps from your tool results — never fabricate data.
        - If you search and find nothing relevant, return {"suggestions": []}.
        - Don't repeat the last suggestion shown (if any).

        ## Output Format

        Output ONLY valid JSON (no markdown, no explanation, no code fences):
        {"suggestions": [{"type": "followup|meeting_prep|workload_pattern|reminder|context_switch|daily_digest", \
        "title": "Short actionable title (under 60 chars)", "body": "1-2 sentence explanation with specifics", \
        "whyNow": "Why this is relevant to what the user is doing right now", "confidence": 0.75, \
        "evidence": [{"timestamp": 1708300000000000, "app": "AppName", "sourceKind": "tool_name", "snippet": "Brief context"}]}]}
        """

        return prompt
    }

    private static func buildDeepTickPrompt(
        liveContext: LiveContextSnapshot,
        episodes: [EpisodeRecord],
        dailies: [DailyRecord]
    ) -> String {
        var prompt = """
        You are analyzing the user's broader work patterns to surface insights and reminders for \
        their inbox. These are not urgent — they're things for the user to review at their convenience. \
        But they should be specific, evidence-based, and genuinely useful.

        ## Current Context

        - App: \(liveContext.currentApp)
        - Window: \(liveContext.windowTitle)
        """

        let now = Date()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = .current
        prompt += "\n- Current time: \(timeFormatter.string(from: now))"

        let dateStr = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            return f.string(from: now)
        }()

        // Include episode summaries
        if !episodes.isEmpty {
            prompt += "\n\n## Recent Memory (Episode Summaries)"
            for ep in episodes {
                let startStr = formatTimestamp(ep.startUs)
                let endStr = formatTimestamp(ep.endUs)
                prompt += "\n[\(startStr)-\(endStr)] \(ep.summary)"
                prompt += "\n  Topics: \(ep.topicTags.joined(separator: ", "))"
                prompt += "\n  Apps: \(ep.apps.joined(separator: ", "))"
            }
        }

        // Include daily open loops
        if !dailies.isEmpty {
            for daily in dailies {
                if !daily.openLoops.isEmpty {
                    prompt += "\n\n## Open Items from \(daily.date)"
                    for loop in daily.openLoops {
                        prompt += "\n- \(loop)"
                    }
                }
            }
        }

        prompt += """


        ## Your Tools

        You have full access to the user's captured data. Use multiple tools to build a thorough picture:

        - **search_hybrid(query, limit?)** — Search all captured data: apps, window titles, OCR text, \
        transcripts. Use to find specific people, projects, topics mentioned in episodes or open loops.

        - **get_transcript_window(startUs, endUs, limit?)** — Get audio transcripts in a time range. \
        Entries marked (mic) are the USER's own voice. Entries marked (system) are OTHER PARTICIPANTS. \
        Look for commitments: "I'll have it done by Friday", "let me handle that", "I need to follow up".

        - **search_summaries(query, limit?)** — Search meeting summaries for action items, decisions, \
        and follow-ups. Cross-reference with open loops to find items that haven't been addressed.

        - **resolve_latest_meeting()** — Find the most recent meeting with transcript data. Check if \
        action items from that meeting have been followed up on.

        - **get_day_summary(dateStr)** — Get today's app usage breakdown. Today is \(dateStr). Use this \
        to calculate: total meeting time (Zoom, Teams, etc.), coding time, context switches, longest \
        focused block, total active hours. Compare patterns.

        - **get_activity_sequence(startUs, endUs, limit?)** — Get chronological app transitions. Use to \
        count context switches, identify fragmented vs focused work blocks, and understand workflow.

        - **get_timeline_context(timestampUs, windowMinutes?)** — Drill into a specific moment. Use to \
        get details about something found in episodes or search results.

        - **search_visual_memories(query, limit?)** — Visual search of screen recordings. Use to find \
        specific things the user was looking at.

        - **inspect_screenshots(candidates)** — View actual screen frames. Use after visual search.

        ## Strategy

        1. **Start with get_day_summary** to understand today's overall pattern — how much time in meetings \
        vs coding vs communication, total active hours, longest session.
        2. **Check open loops.** For each open item listed above, search for whether it was addressed. \
        Search for the key terms in each open loop using search_hybrid.
        3. **Check meeting follow-ups.** Use search_summaries to find recent meetings with action items. \
        Then search_hybrid to see if those items were followed up on (did the user open the relevant \
        app/file/email?).
        4. **Look for user commitments.** Use get_transcript_window on recent meeting time ranges to find \
        (mic) entries where the user said "I'll...", "I need to...", "let me..." — these are commitments \
        that may need follow-up.
        5. **Detect workload patterns.** From the day summary: >3 hours in video calls = meeting-heavy day. \
        >200 app switches in 2 hours = high context switching. >4 hours continuous in one app = consider \
        a break. These are worth surfacing.
        6. **Be specific.** "You have 3 unaddressed action items from your 2pm meeting with the design team" \
        is useful. "You had some meetings today" is not.

        ## Tool Budget — Be Purposeful

        You have a generous but finite tool budget. Use it wisely:

        - **Plan your investigation before calling tools.** Decide which 2-3 lines of inquiry are most \
        promising, then execute them. Don't explore randomly.
        - **Typical deep tick: 3-8 tool calls.** Start with get_day_summary (1 call), then 1-2 targeted \
        searches for open loops or meetings, then 1-2 drill-downs if you find something. That's enough.
        - **Batch your entity searches.** If you have 3 open loops to check, search for the most important \
        one first. If it yields nothing, the others likely won't either.
        - **Stop early when there's nothing.** If get_day_summary shows low activity and search_hybrid \
        finds no relevant meetings or commitments, return {"suggestions": []}. Don't keep searching.
        - **Each call should build on the previous one.** Don't call 5 tools in parallel hoping one hits. \
        Use the result of each call to decide whether the next is worth making.
        - **Use parallel tool calls when it makes sense.** If you need to search for two independent things \
        (e.g., checking two open loops), request both in the same turn. This is faster and uses fewer \
        turns, though each still counts against your tool call limit.
        - **Always reserve your last turn for producing the final JSON output.** Don't exhaust your entire \
        budget on tool calls and leave nothing for the answer.
        - **Quality over breadth.** 2 well-chosen tool calls that lead to 1 great suggestion beat \
        10 speculative calls that find nothing.

        ## Rules

        - Generate 0-3 suggestions. Each must have evidence from real data found via tools.
        - Evidence must reference real timestamps from your tool results — never fabricate.
        - If you search and find nothing actionable, return {"suggestions": []}.
        - Quality over quantity — 1 great suggestion beats 3 mediocre ones.

        ## Output Format

        Output ONLY valid JSON (no markdown, no explanation, no code fences):
        {"suggestions": [{"type": "followup|meeting_prep|workload_pattern|reminder|context_switch|daily_digest", \
        "title": "Short actionable title (under 60 chars)", "body": "1-2 sentence explanation with specifics", \
        "whyNow": "Why this matters right now", "confidence": 0.75, \
        "evidence": [{"timestamp": 1708300000000000, "app": "AppName", "sourceKind": "tool_name", "snippet": "Brief context"}]}]}
        """

        return prompt
    }

    // MARK: - Helpers

    private static func formatTimestamp(_ us: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func cleanJSONContent(_ content: String) -> String {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pre-Filter

    /// High-signal apps that always trigger analysis when the user switches to them.
    static let highSignalApps: Set<String> = [
        "Slack", "Mail", "zoom.us", "Microsoft Outlook",
        "Microsoft Teams", "Discord", "Messages"
    ]

    /// Determine if the fast tick should run based on context changes.
    ///
    /// Returns true (should run) when:
    /// - The app changed since last fast tick
    /// - The window title changed since last fast tick
    /// - The user has been in the same app for >30 minutes (stuck signal)
    /// - The current app is a high-signal communication app
    static func shouldRunFastTick(
        liveContext: LiveContextSnapshot,
        lastApp: String?,
        lastWindowTitle: String?
    ) -> Bool {
        // First run — always analyze
        guard let lastApp, let lastWindowTitle else { return true }

        // App changed
        if liveContext.currentApp != lastApp { return true }

        // Window title changed
        if liveContext.windowTitle != lastWindowTitle { return true }

        // Stuck in same app for >30 minutes
        if liveContext.activeSeconds > 1800 { return true }

        // High-signal app — always analyze (even if title didn't change)
        if highSignalApps.contains(liveContext.currentApp) { return true }

        return false
    }
}
