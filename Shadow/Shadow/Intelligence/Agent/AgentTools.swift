import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AgentTools")

/// Factory for agent tools — both read-only V1 tools and AX action tools.
/// Each method returns a (ToolSpec, AgentToolHandler) pair.
///
/// Tool handlers are injectable for testing via closure parameters.
/// Default closures call the real UniFFI/Swift APIs.
enum AgentTools {

    /// Build the default tool registry with all tools.
    ///
    /// - Parameters:
    ///   - visionProvider: Optional VisionLLMProvider for on-device screenshot analysis.
    ///     When provided and available, `inspect_screenshots` includes VLM textual descriptions
    ///     alongside the base64 images. This enhances the tool for local text LLMs that cannot
    ///     process raw images.
    ///   - procedureExecutor: Optional shared ProcedureExecutor for replay_procedure tool.
    ///     When provided, procedure replays use this shared instance (enabling kill switch
    ///     and progress UI wiring). When nil, a new executor is created per call.
    static func buildDefaultRegistry(
        visionProvider: VisionLLMProvider? = nil,
        orchestrator: LLMOrchestrator? = nil,
        procedureExecutor: ProcedureExecutor? = nil,
        onExecutionStarted: (@MainActor @Sendable (ProcedureTemplate) -> Void)? = nil,
        onExecutionEvent: (@MainActor @Sendable (ExecutionEvent) -> Void)? = nil
    ) -> AgentToolRegistry {
        var tools: [String: RegisteredTool] = [
            "search_hybrid": searchHybridTool(),
            "get_transcript_window": getTranscriptWindowTool(),
            "get_timeline_context": getTimelineContextTool(),
            "get_day_summary": getDaySummaryTool(),
            "resolve_latest_meeting": resolveLatestMeetingTool(),
            "get_activity_sequence": getActivitySequenceTool(),
            "search_summaries": searchSummariesTool(),
        ]

        // Visual tools — CLIPEncoder may be nil when models are not provisioned
        let clipEncoder = CLIPEncoder()

        tools["search_visual_memories"] = searchVisualMemoriesTool(
            textEmbedder: { query in clipEncoder?.embedText(query) },
            searcher: { query, vec, limit in
                try searchHybrid(query: query, queryVector: vec, limit: limit)
            },
            rangeSearcher: { query, vec, startUs, endUs, limit in
                try searchHybridInRange(query: query, queryVector: vec, startUs: startUs, endUs: endUs, limit: limit)
            }
        )

        // Build VLM analyzer closure — check availability dynamically at call time,
        // not at registry construction time, so the tool picks up models downloaded
        // after startup by the background provisioner.
        let vlmAnalyzer: (@Sendable (CGImage, String) async throws -> String)?
        if let visionProvider {
            vlmAnalyzer = { image, query in
                guard visionProvider.isAvailable else {
                    // VLM not available yet — return empty to fall back to OCR
                    return ""
                }
                return try await visionProvider.analyze(image: image, query: query)
            }
        } else {
            vlmAnalyzer = nil
        }
        DiagnosticsStore.shared.setGauge("vlm_available", value: visionProvider?.isAvailable == true ? 1 : 0)

        tools["inspect_screenshots"] = inspectScreenshotsTool(
            frameExtractor: { ts, displayId in
                try await FrameExtractor.extractFrame(at: ts, displayID: CGDirectDisplayID(displayId))
            },
            vlmAnalyzer: vlmAnalyzer
        )

        // AX action tools — give the agent ability to read and control the UI
        registerAXTools(
            into: &tools,
            orchestrator: orchestrator,
            procedureExecutor: procedureExecutor,
            onExecutionStarted: onExecutionStarted,
            onExecutionEvent: onExecutionEvent
        )

        // Memory tools — semantic knowledge and directives
        registerMemoryTools(into: &tools)

        return AgentToolRegistry(tools: tools)
    }

    // MARK: - Schema Helpers

    /// Build a JSON Schema property descriptor.
    static func prop(_ type: String, _ description: String) -> AnyCodable {
        .dictionary([
            "type": .string(type),
            "description": .string(description),
        ])
    }

    /// Build a JSON Schema object with properties and required fields.
    static func objectSchema(
        properties: [String: AnyCodable],
        required: [String]
    ) -> [String: AnyCodable] {
        [
            "type": .string("object"),
            "properties": .dictionary(properties),
            "required": .array(required.map { .string($0) }),
        ]
    }

    // MARK: - Validated Numeric Parsing

    /// Parse a non-negative Int from an optional AnyCodable, clamped to [min, max].
    /// Returns `defaultValue` when the arg is nil.
    /// Throws `ToolError.invalidArgument` when the value is present but negative or non-numeric.
    static func parseClampedInt(
        _ args: [String: AnyCodable],
        key: String,
        defaultValue: Int,
        min minVal: Int,
        max maxVal: Int
    ) throws -> Int {
        guard let raw = args[key] else { return defaultValue }
        guard let value = raw.intValue else {
            throw ToolError.invalidArgument(key, detail: "expected integer")
        }
        if value < 0 {
            throw ToolError.invalidArgument(key, detail: "must be non-negative, got \(value)")
        }
        return min(max(value, minVal), maxVal)
    }

    /// Parse a UInt32 from a clamped Int. Validates non-negative before UInt32 conversion.
    static func parseClampedUInt32(
        _ args: [String: AnyCodable],
        key: String,
        defaultValue: Int,
        min minVal: Int,
        max maxVal: Int
    ) throws -> UInt32 {
        let clamped = try parseClampedInt(args, key: key, defaultValue: defaultValue, min: minVal, max: maxVal)
        return UInt32(clamped)
    }

    /// Parse a required UInt64 timestamp. Throws on missing/negative.
    static func parseRequiredUInt64(
        _ args: [String: AnyCodable],
        key: String
    ) throws -> UInt64 {
        guard let raw = args[key] else {
            throw ToolError.missingArgument(key)
        }
        guard let value = raw.uint64Value else {
            // uint64Value already returns nil for negative Ints
            throw ToolError.invalidArgument(key, detail: "expected non-negative integer")
        }
        return value
    }

    // MARK: - search_hybrid

    static func searchHybridTool(
        searcher: @escaping @Sendable (String, UInt32) throws -> [SearchResult] = { query, limit in
            try searchHybrid(query: query, queryVector: [], limit: limit)
        },
        rangeSearcher: @escaping @Sendable (String, UInt64, UInt64, UInt32) throws -> [SearchResult] = { query, startUs, endUs, limit in
            try searchHybridInRange(query: query, queryVector: [], startUs: startUs, endUs: endUs, limit: limit)
        },
        indexer: @escaping @Sendable () throws -> UInt32 = { try indexRecentEvents() }
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "search_hybrid",
            description: "Search the user's captured timeline for apps, windows, OCR text, and transcripts. Returns matches ranked by relevance. Supports optional time range filtering.",
            inputSchema: objectSchema(
                properties: [
                    "query": prop("string", "Search query text"),
                    "startUs": prop("integer", "Start timestamp (Unix microseconds, optional — omit for global search)"),
                    "endUs": prop("integer", "End timestamp (Unix microseconds, optional — must pair with startUs)"),
                    "limit": prop("integer", "Maximum results (default 10, max 50)"),
                ],
                required: ["query"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let query = args["query"]?.stringValue, !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }
            let clamped = try parseClampedUInt32(args, key: "limit", defaultValue: 10, min: 1, max: 50)

            // Parse optional time range
            let startUs = args["startUs"]?.uint64Value
            let endUs = args["endUs"]?.uint64Value

            // Validate partial time-range args
            if (startUs != nil) != (endUs != nil) {
                throw ToolError.invalidArgument(
                    startUs != nil ? "endUs" : "startUs",
                    detail: "Both startUs and endUs must be provided for time-range filtering, or omit both for global search"
                )
            }

            let _ = try indexer()

            let results: [SearchResult]
            if let startUs, let endUs {
                guard startUs <= endUs else {
                    throw ToolError.invalidArgument("startUs", detail: "startUs must be <= endUs")
                }
                results = try rangeSearcher(query, startUs, endUs, clamped)
            } else {
                results = try searcher(query, clamped)
            }

            return results.map { r in
                var fields: [String: Any] = [
                    "ts": r.ts,
                    "app": r.appName,
                    "sourceKind": r.sourceKind,
                    "matchReason": r.matchReason,
                ]
                if !r.windowTitle.isEmpty { fields["title"] = r.windowTitle }
                if !r.url.isEmpty { fields["url"] = r.url }
                if !r.snippet.isEmpty { fields["snippet"] = r.snippet }
                if let did = r.displayId { fields["displayId"] = did }
                if !r.audioSource.isEmpty { fields["audioSource"] = r.audioSource }
                if let segId = r.audioSegmentId { fields["audioSegmentId"] = segId }
                if r.tsEnd > 0 { fields["tsEnd"] = r.tsEnd }
                if let conf = r.confidence { fields["confidence"] = conf }
                return formatJSONLine(fields)
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - get_transcript_window

    static func getTranscriptWindowTool(
        fetcher: @escaping @Sendable (UInt64, UInt64, UInt32, UInt32) throws -> [TranscriptChunkResult] = { startUs, endUs, limit, offset in
            try listTranscriptChunksInRange(startUs: startUs, endUs: endUs, limit: limit, offset: offset)
        }
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "get_transcript_window",
            description: "Retrieve audio transcript chunks within a time window. Returns timestamped text with source labels.",
            inputSchema: objectSchema(
                properties: [
                    "startUs": prop("integer", "Start timestamp (Unix microseconds)"),
                    "endUs": prop("integer", "End timestamp (Unix microseconds)"),
                    "limit": prop("integer", "Maximum chunks (default 100)"),
                    "offset": prop("integer", "Pagination offset (default 0)"),
                ],
                required: ["startUs", "endUs"]
            )
        )

        let handler: AgentToolHandler = { args in
            let startUs = try parseRequiredUInt64(args, key: "startUs")
            let endUs = try parseRequiredUInt64(args, key: "endUs")
            let limit = try parseClampedUInt32(args, key: "limit", defaultValue: 100, min: 1, max: 1000)
            let offset = try parseClampedUInt32(args, key: "offset", defaultValue: 0, min: 0, max: 100_000)

            let chunks = try fetcher(startUs, endUs, limit, offset)

            return chunks.map { c in
                var fields: [String: Any] = [
                    "tsStart": c.tsStart,
                    "tsEnd": c.tsEnd,
                    "text": c.text,
                    "audioSource": c.audioSource,
                ]
                if !c.appName.isEmpty { fields["appName"] = c.appName }
                if !c.windowTitle.isEmpty { fields["windowTitle"] = c.windowTitle }
                if let conf = c.confidence { fields["confidence"] = conf }
                return formatJSONLine(fields)
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - get_timeline_context

    static func getTimelineContextTool(
        appFinder: @escaping @Sendable (UInt64) throws -> AppContext? = { ts in
            try findAppAtTimestamp(timestampUs: ts)
        },
        rangeQuery: @escaping @Sendable (UInt64, UInt64) throws -> [TimelineEntry] = { startUs, endUs in
            try queryTimeRange(startUs: startUs, endUs: endUs)
        }
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "get_timeline_context",
            description: "Get app context and nearby activity around a specific timestamp. Shows what was happening at that moment.",
            inputSchema: objectSchema(
                properties: [
                    "timestampUs": prop("integer", "Target timestamp (Unix microseconds)"),
                    "windowMinutes": prop("integer", "Context window in minutes (default 5, max 30)"),
                ],
                required: ["timestampUs"]
            )
        )

        let handler: AgentToolHandler = { args in
            let tsUs = try parseRequiredUInt64(args, key: "timestampUs")
            let windowMinutes = try parseClampedInt(args, key: "windowMinutes", defaultValue: 5, min: 1, max: 30)
            let windowUs = UInt64(windowMinutes) * 60 * 1_000_000
            let startUs = tsUs > windowUs ? tsUs - windowUs : 0
            let endUs = tsUs + windowUs

            // Point-in-time app context
            let appCtx = try appFinder(tsUs)

            // Nearby events
            let events = try rangeQuery(startUs, endUs)

            var lines: [String] = []

            // Current app context
            if let ctx = appCtx {
                lines.append(formatJSONLine([
                    "type": "current_app",
                    "app": ctx.appName,
                    "bundleId": ctx.bundleId as Any,
                    "timestampUs": tsUs,
                ]))
            }

            // Nearby app switches (Track 3) as context
            let appSwitches = events.filter { $0.eventType == "app_switch" }
            for event in appSwitches.prefix(20) {
                var fields: [String: Any] = [
                    "type": "nearby_event",
                    "ts": event.ts,
                    "app": event.appName as Any,
                ]
                if let title = event.windowTitle, !title.isEmpty { fields["title"] = title }
                if let url = event.url, !url.isEmpty { fields["url"] = url }
                if let did = event.displayId { fields["displayId"] = did }
                lines.append(formatJSONLine(fields))
            }

            return lines.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - get_day_summary

    static func getDaySummaryTool(
        fetcher: @escaping @Sendable (String) throws -> [ActivityBlock] = { dateStr in
            try getDaySummary(dateStr: dateStr)
        }
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "get_day_summary",
            description: "Get a summary of app activity for a specific day. Shows which apps were used and for how long.",
            inputSchema: objectSchema(
                properties: [
                    "dateStr": prop("string", "Date in YYYY-MM-DD format"),
                ],
                required: ["dateStr"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let dateStr = args["dateStr"]?.stringValue, !dateStr.isEmpty else {
                throw ToolError.missingArgument("dateStr")
            }

            let blocks = try fetcher(dateStr)

            return blocks.map { b in
                let durationSec = Double(b.endTs - b.startTs) / 1_000_000
                return formatJSONLine([
                    "app": b.appName,
                    "startTs": b.startTs,
                    "endTs": b.endTs,
                    "durationSec": Int(durationSec),
                    "eventCount": b.eventCount,
                ])
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - resolve_latest_meeting

    static func resolveLatestMeetingTool(
        resolver: @escaping @Sendable (UInt64, UInt64) throws -> [MeetingCandidate] = { startUs, endUs in
            try MeetingResolver.resolveMeetingsInRange(startUs: startUs, endUs: endUs)
        }
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "resolve_latest_meeting",
            description: "Find meetings (video calls, huddles, any conversation with audio) in a time range. Detects meetings via audio overlap (mic + system audio). Returns candidate windows with timestamps and confidence scores. Use get_transcript_window to read the full transcript for any candidate.",
            inputSchema: objectSchema(
                properties: [
                    "lookbackHours": prop("integer", "Hours to look back from now (default 24, max 168). Ignored if startUs/endUs provided."),
                    "startUs": prop("integer", "Start timestamp (Unix microseconds, optional — for finding meetings in a specific window)"),
                    "endUs": prop("integer", "End timestamp (Unix microseconds, optional — must pair with startUs)"),
                ],
                required: []
            )
        )

        let handler: AgentToolHandler = { args in
            let startUs: UInt64
            let endUs: UInt64

            if let s = args["startUs"]?.uint64Value, let e = args["endUs"]?.uint64Value {
                guard s <= e else {
                    throw ToolError.invalidArgument("startUs", detail: "startUs must be <= endUs")
                }
                startUs = s
                endUs = e
            } else if args["startUs"] != nil || args["endUs"] != nil {
                throw ToolError.invalidArgument(
                    args["startUs"] != nil ? "endUs" : "startUs",
                    detail: "Both startUs and endUs must be provided, or omit both"
                )
            } else {
                let lookback = try parseClampedInt(args, key: "lookbackHours", defaultValue: 24, min: 1, max: 168)
                let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                let lookbackUs = UInt64(lookback) * 3600 * 1_000_000
                startUs = now - lookbackUs
                endUs = now
            }

            let candidates = try resolver(startUs, endUs)

            if candidates.isEmpty {
                return formatJSONLine(["result": "no_meeting_found"])
            }

            return candidates.map { c in
                formatJSONLine([
                    "app": c.app,
                    "startUs": c.startUs,
                    "endUs": c.endUs,
                    "transcriptChunkCount": c.transcriptChunkCount,
                    "confidence": String(format: "%.2f", c.confidence),
                ])
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - get_activity_sequence

    static func getActivitySequenceTool(
        rangeQuery: @escaping @Sendable (UInt64, UInt64) throws -> [TimelineEntry] = { startUs, endUs in
            try queryTimeRange(startUs: startUs, endUs: endUs)
        }
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "get_activity_sequence",
            description: "Get a chronological sequence of app transitions in a time window. Shows what the user did in order, with window titles and URLs.",
            inputSchema: objectSchema(
                properties: [
                    "startUs": prop("integer", "Start timestamp (Unix microseconds)"),
                    "endUs": prop("integer", "End timestamp (Unix microseconds)"),
                    "limit": prop("integer", "Maximum transitions (default 30, max 100)"),
                ],
                required: ["startUs", "endUs"]
            )
        )

        let handler: AgentToolHandler = { args in
            let startUs = try parseRequiredUInt64(args, key: "startUs")
            let endUs = try parseRequiredUInt64(args, key: "endUs")
            let limit = try parseClampedInt(args, key: "limit", defaultValue: 30, min: 1, max: 100)

            let events = try rangeQuery(startUs, endUs)

            // Filter to Track 3 app_switch events and build intervals
            let appSwitches = events
                .filter { $0.eventType == "app_switch" }
                .sorted { $0.ts < $1.ts }

            var intervals: [(app: String, title: String?, url: String?, displayId: UInt32?, startTs: UInt64, endTs: UInt64)] = []

            for (i, event) in appSwitches.enumerated() {
                let nextTs = (i + 1 < appSwitches.count) ? appSwitches[i + 1].ts : endUs
                intervals.append((
                    app: event.appName ?? "Unknown",
                    title: event.windowTitle,
                    url: event.url,
                    displayId: event.displayId,
                    startTs: event.ts,
                    endTs: nextTs
                ))
            }

            return intervals.prefix(limit).map { iv in
                let durationSec = Double(iv.endTs - iv.startTs) / 1_000_000
                var fields: [String: Any] = [
                    "app": iv.app,
                    "startTs": iv.startTs,
                    "endTs": iv.endTs,
                    "durationSec": Int(durationSec),
                ]
                if let title = iv.title, !title.isEmpty { fields["windowTitle"] = title }
                if let url = iv.url, !url.isEmpty { fields["url"] = url }
                if let did = iv.displayId { fields["displayId"] = did }
                return formatJSONLine(fields)
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - search_summaries

    static func searchSummariesTool(
        store: SummaryStore = SummaryStore()
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "search_summaries",
            description: "Search previously generated meeting summaries. Finds summaries matching a query by title or content.",
            inputSchema: objectSchema(
                properties: [
                    "query": prop("string", "Search query for summary title or content"),
                    "limit": prop("integer", "Maximum results (default 5, max 20)"),
                ],
                required: ["query"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let query = args["query"]?.stringValue, !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }
            let limit = try parseClampedInt(args, key: "limit", defaultValue: 5, min: 1, max: 20)

            let allSummaries = store.listAll()
            let queryLower = query.lowercased()

            let matches = allSummaries.filter { s in
                s.title.lowercased().contains(queryLower)
                || s.summary.lowercased().contains(queryLower)
                || s.keyPoints.contains { $0.lowercased().contains(queryLower) }
            }.prefix(limit)

            if matches.isEmpty {
                return formatJSONLine(["result": "no_matching_summaries"])
            }

            return matches.map { s in
                let snippet = String(s.summary.prefix(500))
                var fields: [String: Any] = [
                    "id": s.id,
                    "title": s.title,
                    "snippet": snippet,
                    "keyPoints": s.keyPoints,
                    "actionItemCount": s.actionItems.count,
                    "decisionCount": s.decisions.count,
                    "provider": s.metadata.provider,
                    "modelId": s.metadata.modelId,
                    "startUs": s.metadata.sourceWindow.startUs,
                    "endUs": s.metadata.sourceWindow.endUs,
                ]
                if !s.metadata.sourceWindow.timezone.isEmpty {
                    fields["timezone"] = s.metadata.sourceWindow.timezone
                }
                // Inline action items for small summaries (avoids bloating output for long meetings)
                if s.actionItems.count <= 5 && !s.actionItems.isEmpty {
                    fields["actionItems"] = s.actionItems.map { item -> [String: Any] in
                        var d: [String: Any] = ["description": item.description]
                        if let owner = item.owner { d["owner"] = owner }
                        return d
                    }
                }
                return formatJSONLine(fields)
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - search_visual_memories

    static func searchVisualMemoriesTool(
        textEmbedder: @escaping @Sendable (String) -> [Float]?,
        searcher: @escaping @Sendable (String, [Float], UInt32) throws -> [SearchResult],
        rangeSearcher: @escaping @Sendable (String, [Float], UInt64, UInt64, UInt32) throws -> [SearchResult],
        indexer: @escaping @Sendable () throws -> UInt32 = { try indexRecentEvents() }
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "search_visual_memories",
            description: "Search the user's screen recordings visually using CLIP embeddings. Finds frames that match a text description. Optionally filter by time range.",
            inputSchema: objectSchema(
                properties: [
                    "query": prop("string", "Text description of what to search for visually"),
                    "startUs": prop("integer", "Start timestamp (Unix microseconds, optional)"),
                    "endUs": prop("integer", "End timestamp (Unix microseconds, optional)"),
                    "limit": prop("integer", "Maximum results (default 5, max 8)"),
                    "minScore": prop("number", "Minimum similarity score to include (0.0-1.0, optional)"),
                ],
                required: ["query"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let query = args["query"]?.stringValue, !query.isEmpty else {
                throw ToolError.missingArgument("query")
            }

            DiagnosticsStore.shared.increment("visual_search_tool_call_total")

            // Embed query text
            guard let queryVector = textEmbedder(query) else {
                return "Visual search unavailable — CLIP models not loaded. Use search_hybrid for text-based results."
            }

            let limit = try parseClampedUInt32(args, key: "limit", defaultValue: 5, min: 1, max: 8)

            // Ensure latest events are indexed before searching
            let _ = try indexer()

            // Parse optional time range
            let startUs = args["startUs"]?.uint64Value
            let endUs = args["endUs"]?.uint64Value

            // P3: Validate partial time-range args
            if (startUs != nil) != (endUs != nil) {
                throw ToolError.invalidArgument(
                    startUs != nil ? "endUs" : "startUs",
                    detail: "Both startUs and endUs must be provided for time-range filtering, or omit both for global search"
                )
            }

            let results: [SearchResult]
            if let startUs = startUs, let endUs = endUs {
                // Validate ordering
                guard startUs <= endUs else {
                    throw ToolError.invalidArgument("startUs", detail: "startUs must be <= endUs")
                }
                results = try rangeSearcher(query, queryVector, startUs, endUs, limit)
            } else {
                results = try searcher(query, queryVector, limit)
            }

            // Filter to visual-only results
            let visualResults = results.filter { r in
                r.matchReason.contains("visual") || r.sourceKind == "visual"
            }

            // Apply minScore filter
            let minScore: Float
            if let raw = args["minScore"]?.doubleValue {
                minScore = Float(raw)
            } else {
                minScore = 0.0
            }

            let filtered = visualResults
                .filter { $0.score >= minScore }
                .sorted { a, b in
                    if a.score != b.score { return a.score > b.score }
                    return a.ts > b.ts  // timestamp desc tie-break
                }

            if filtered.isEmpty {
                return formatJSONLine(["result": "no_visual_matches", "query": query])
            }

            return filtered.map { r in
                var fields: [String: Any] = [
                    "ts": r.ts,
                    "score": String(format: "%.3f", r.score),
                    "sourceKind": r.sourceKind,
                ]
                if !r.appName.isEmpty { fields["app"] = r.appName }
                if let did = r.displayId { fields["displayId"] = did }
                if !r.windowTitle.isEmpty { fields["title"] = r.windowTitle }
                if !r.url.isEmpty { fields["url"] = r.url }
                if !r.snippet.isEmpty { fields["snippet"] = r.snippet }
                return formatJSONLine(fields)
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - inspect_screenshots

    static func inspectScreenshotsTool(
        frameExtractor: @escaping @Sendable (TimeInterval, UInt32) async throws -> CGImage?,
        vlmAnalyzer: (@Sendable (CGImage, String) async throws -> String)? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "inspect_screenshots",
            description: "Extract and inspect actual screen frames at specific timestamps. Returns the frames as images for visual analysis. Use after search_visual_memories to examine specific moments.",
            inputSchema: objectSchema(
                properties: [
                    "candidates": .dictionary([
                        "type": .string("array"),
                        "description": .string("Array of candidates to inspect, each with timestampUs and displayId"),
                        "items": .dictionary([
                            "type": .string("object"),
                            "properties": .dictionary([
                                "timestampUs": .dictionary([
                                    "type": .string("integer"),
                                    "description": .string("Frame timestamp (Unix microseconds)"),
                                ]),
                                "displayId": .dictionary([
                                    "type": .string("integer"),
                                    "description": .string("Display ID"),
                                ]),
                            ]),
                            "required": .array([.string("timestampUs"), .string("displayId")]),
                        ]),
                    ]),
                ],
                required: ["candidates"]
            )
        )

        let imageHandler: AgentImageToolHandler = { args in
            DiagnosticsStore.shared.increment("visual_inspect_tool_call_total")

            guard let candidatesRaw = args["candidates"]?.arrayValue else {
                throw ToolError.missingArgument("candidates")
            }

            if candidatesRaw.count > 4 {
                throw ToolError.invalidArgument("candidates", detail: "Maximum 4 candidates per call, got \(candidatesRaw.count)")
            }

            var images: [ImageData] = []
            var summaryLines: [String] = []
            var cumulativeBytes = 0
            let maxBytesPerImage = 300_000     // 300KB JPEG
            let maxCumulativeBytes = 1_500_000 // 1.5MB total
            var encodedCount = 0
            var skippedCount = 0

            for (i, candidate) in candidatesRaw.enumerated() {
                guard let dict = candidate.dictionaryValue,
                      let tsUs = dict["timestampUs"]?.uint64Value,
                      let displayIdRaw = dict["displayId"]?.uint64Value else {
                    summaryLines.append(formatJSONLine([
                        "index": i, "status": "skipped", "reason": "missing timestampUs or displayId"
                    ]))
                    skippedCount += 1
                    continue
                }

                // Validate displayId fits in UInt32 (CGDirectDisplayID range)
                guard displayIdRaw <= UInt32.max else {
                    summaryLines.append(formatJSONLine([
                        "index": i, "ts": tsUs, "displayId": displayIdRaw,
                        "status": "skipped", "reason": "displayId exceeds UInt32 range"
                    ]))
                    skippedCount += 1
                    continue
                }
                let displayId = UInt32(displayIdRaw)

                let seconds = TimeInterval(tsUs) / 1_000_000.0

                do {
                    // Try exact timestamp first, then fall back to 2s and 5s earlier.
                    // This handles the edge case where the agent requests the current moment
                    // but the frame hasn't been written yet (1-2 second recording delay).
                    var frame: CGImage?
                    var usedTs = tsUs
                    for fallbackOffsetSec in [0.0, 2.0, 5.0] {
                        let trySeconds = seconds - fallbackOffsetSec
                        guard trySeconds > 0 else { continue }
                        frame = try await frameExtractor(trySeconds, displayId)
                        if frame != nil {
                            usedTs = UInt64(trySeconds * 1_000_000)
                            break
                        }
                    }

                    guard let frame else {
                        summaryLines.append(formatJSONLine([
                            "index": i, "ts": tsUs, "displayId": displayId, "status": "no_frame"
                        ]))
                        skippedCount += 1
                        continue
                    }

                    guard let jpegData = encodeFrameAsJPEG(frame, maxWidth: 768, quality: 0.5) else {
                        summaryLines.append(formatJSONLine([
                            "index": i, "ts": tsUs, "displayId": displayId, "status": "encode_failed"
                        ]))
                        skippedCount += 1
                        continue
                    }

                    // Size budget checks
                    if jpegData.count > maxBytesPerImage {
                        summaryLines.append(formatJSONLine([
                            "index": i, "ts": tsUs, "displayId": displayId,
                            "status": "skipped_too_large", "bytes": jpegData.count
                        ]))
                        skippedCount += 1
                        DiagnosticsStore.shared.increment("visual_images_skipped_total")
                        continue
                    }

                    if cumulativeBytes + jpegData.count > maxCumulativeBytes {
                        summaryLines.append(formatJSONLine([
                            "index": i, "ts": tsUs, "displayId": displayId,
                            "status": "skipped_budget_exceeded"
                        ]))
                        skippedCount += 1
                        DiagnosticsStore.shared.increment("visual_images_skipped_total")
                        continue
                    }

                    let base64 = jpegData.base64EncodedString()
                    images.append(ImageData(mediaType: "image/jpeg", base64Data: base64))
                    cumulativeBytes += jpegData.count
                    encodedCount += 1
                    DiagnosticsStore.shared.increment("visual_images_encoded_total")
                    DiagnosticsStore.shared.increment("visual_payload_bytes_total", by: Int64(jpegData.count))

                    var extractedFields: [String: Any] = [
                        "index": i, "ts": usedTs, "displayId": displayId,
                        "status": "extracted", "bytes": jpegData.count,
                        "width": frame.width, "height": frame.height
                    ]
                    if usedTs != tsUs {
                        extractedFields["requestedTs"] = tsUs
                        extractedFields["fallbackNote"] = "Used frame \(Int((TimeInterval(tsUs - usedTs) / 1_000_000)))s earlier"
                    }

                    // VLM enhancement: if available, run on-device vision analysis.
                    // This provides textual descriptions that work with local text LLMs
                    // (which cannot process raw images), complementing the base64 images
                    // sent to cloud providers.
                    if let vlmAnalyzer {
                        let vlmQuery = "Describe what is shown on this screen. Include: the app name, key UI elements, any visible text, charts, images, or data. What task does this suggest the user is performing?"
                        do {
                            let analysis = try await vlmAnalyzer(frame, vlmQuery)
                            extractedFields["vlmAnalysis"] = analysis
                            DiagnosticsStore.shared.increment("vlm_inspect_success_total")
                        } catch {
                            // VLM analysis is best-effort — don't fail the whole extraction
                            extractedFields["vlmError"] = error.localizedDescription
                            DiagnosticsStore.shared.increment("vlm_inspect_fail_total")
                        }
                    }

                    summaryLines.append(formatJSONLine(extractedFields))
                } catch {
                    summaryLines.append(formatJSONLine([
                        "index": i, "ts": tsUs, "displayId": displayId,
                        "status": "error", "message": error.localizedDescription
                    ]))
                    skippedCount += 1
                }
            }

            if images.isEmpty {
                DiagnosticsStore.shared.increment("visual_inspect_fail_total")
            }

            let text = summaryLines.joined(separator: "\n")
            return AgentToolOutput(text: text, images: images)
        }

        return RegisteredTool(spec: spec, imageHandler: imageHandler)
    }

    // MARK: - Image Encoding

    /// Resize a CGImage and encode as JPEG data.
    static func encodeFrameAsJPEG(_ image: CGImage, maxWidth: Int, quality: CGFloat) -> Data? {
        let originalWidth = image.width
        let originalHeight = image.height

        let targetWidth: Int
        let targetHeight: Int
        if originalWidth > maxWidth {
            let scale = CGFloat(maxWidth) / CGFloat(originalWidth)
            targetWidth = maxWidth
            targetHeight = Int(CGFloat(originalHeight) * scale)
        } else {
            targetWidth = originalWidth
            targetHeight = originalHeight
        }

        // Create resized bitmap context
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let resizedImage = context.makeImage() else {
            return nil
        }

        // Encode as JPEG using NSBitmapImageRep
        let bitmapRep = NSBitmapImageRep(cgImage: resizedImage)
        return bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
    }

    // MARK: - Helpers

    /// Format a dictionary as a compact JSON line.
    /// Falls back to key=value format if JSON serialization fails.
    static func formatJSONLine(_ fields: [String: Any]) -> String {
        // Filter out NSNull and nil-coerced Optional<Any>
        let cleaned = fields.compactMapValues { value -> Any? in
            if value is NSNull { return nil }
            // Handle Optional wrapped in Any
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                guard let child = mirror.children.first else { return nil }
                return child.value
            }
            return value
        }

        if let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        // Fallback
        return cleaned.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }
}

// MARK: - Tool Error

/// Errors thrown by tool handler argument validation.
enum ToolError: Error, LocalizedError {
    case missingArgument(String)
    case invalidArgument(String, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .invalidArgument(let name, let detail):
            return "Invalid argument '\(name)': \(detail)"
        }
    }
}

// MARK: - AnyCodable Value Extraction

extension AnyCodable {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        if case .string(let s) = self { return Int(s) }
        return nil
    }

    var uint64Value: UInt64? {
        if case .int(let i) = self { return i >= 0 ? UInt64(i) : nil }
        if case .double(let d) = self { return d >= 0 ? UInt64(d) : nil }
        if case .string(let s) = self { return UInt64(s) }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        if case .string(let s) = self { return Double(s) }
        return nil
    }

    var arrayValue: [AnyCodable]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var dictionaryValue: [String: AnyCodable]? {
        if case .dictionary(let d) = self { return d }
        return nil
    }
}
