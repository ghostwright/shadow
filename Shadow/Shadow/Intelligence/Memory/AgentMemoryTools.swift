import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AgentMemoryTools")

// MARK: - Memory Agent Tools

/// Factory methods for memory-related agent tools.
/// These give the agent the ability to read/write semantic knowledge and directives.
extension AgentTools {

    /// Register all memory tools into an existing tool dictionary.
    static func registerMemoryTools(into tools: inout [String: RegisteredTool]) {
        tools["get_knowledge"] = getKnowledgeTool()
        tools["set_directive"] = setDirectiveTool()
        tools["get_directives"] = getDirectivesTool()
    }

    // MARK: - get_knowledge

    /// Query semantic knowledge from long-term memory.
    static func getKnowledgeTool(
        queryFn: SemanticMemoryStore.QueryFn? = nil,
        touchFn: SemanticMemoryStore.TouchFn? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "get_knowledge",
            description: "Query the user's long-term semantic memory. Returns learned facts, preferences, patterns, and behavioral knowledge. Use this to personalize responses and understand the user's habits. Categories: preference, fact, pattern, relationship, skill.",
            inputSchema: objectSchema(
                properties: [
                    "category": prop("string", "Filter by knowledge category: preference, fact, pattern, relationship, skill. Optional — omit to search all."),
                    "limit": prop("integer", "Maximum results (default 10, max 50)"),
                ],
                required: []
            )
        )

        let handler: AgentToolHandler = { args in
            let category = args["category"]?.stringValue
            let limit = try parseClampedInt(args, key: "limit", defaultValue: 10, min: 1, max: 50)

            let effectiveQueryFn: SemanticMemoryStore.QueryFn = queryFn ?? { cat, lim in
                try querySemanticKnowledge(category: cat, limit: lim)
            }
            let effectiveTouchFn: SemanticMemoryStore.TouchFn = touchFn ?? { id, nowUs in
                try touchSemanticKnowledge(id: id, nowUs: nowUs)
            }

            let knowledge = try SemanticMemoryStore.query(
                category: category,
                limit: UInt32(limit),
                queryFn: effectiveQueryFn
            )

            if knowledge.isEmpty {
                return formatJSONLine(["result": "no_knowledge_found", "category": category ?? "all"])
            }

            let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)

            return knowledge.prefix(limit).map { k in
                // Touch each accessed entry
                try? SemanticMemoryStore.touch(id: k.id, nowUs: nowUs, touchFn: effectiveTouchFn)

                var fields: [String: Any] = [
                    "id": k.id,
                    "category": k.category,
                    "key": k.key,
                    "value": k.value,
                    "confidence": String(format: "%.2f", k.confidence),
                ]
                if k.accessCount > 0 { fields["accessCount"] = k.accessCount }
                if !k.sourceEpisodeIds.isEmpty {
                    fields["sourceEpisodes"] = k.sourceEpisodeIds.count
                }
                return formatJSONLine(fields)
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - set_directive

    /// Create or update a directive (reminder, automation trigger, watch).
    static func setDirectiveTool(
        upsertFn: DirectiveMemoryStore.UpsertFn? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "set_directive",
            description: "Create a directive — a persistent instruction for the agent. Types: 'reminder' (trigger-based reminders), 'habit' (recurring behavioral nudges), 'automation' (auto-run a procedure when condition matches), 'watch' (monitor and alert). Directives persist across sessions and can have optional TTL.",
            inputSchema: objectSchema(
                properties: [
                    "type": prop("string", "Directive type: reminder, habit, automation, watch"),
                    "trigger": prop("string", "Trigger pattern — when to activate (e.g., 'opens Slack', 'after 2h focus', 'PR merged')"),
                    "action": prop("string", "What to do when triggered (e.g., 'Check standup channel', 'Suggest a break')"),
                    "priority": prop("integer", "Priority 1-10 (default 5). Higher = checked first."),
                    "ttlHours": prop("number", "Time-to-live in hours. Directive auto-expires after this duration. Optional — omit for permanent."),
                    "context": prop("string", "Source context — why this directive was created. Optional."),
                ],
                required: ["type", "trigger", "action"]
            )
        )

        let handler: AgentToolHandler = { args in
            guard let directiveType = args["type"]?.stringValue else {
                throw ToolError.missingArgument("type")
            }
            guard let trigger = args["trigger"]?.stringValue else {
                throw ToolError.missingArgument("trigger")
            }
            guard let action = args["action"]?.stringValue else {
                throw ToolError.missingArgument("action")
            }

            let validTypes: Set<String> = ["reminder", "habit", "automation", "watch"]
            guard validTypes.contains(directiveType) else {
                throw ToolError.invalidArgument("type", detail: "must be: reminder, habit, automation, or watch")
            }

            let priority = try parseClampedInt(args, key: "priority", defaultValue: 5, min: 1, max: 10)
            let context = args["context"]?.stringValue ?? ""

            let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let expiresAt: UInt64?
            if let ttlHours = args["ttlHours"]?.doubleValue, ttlHours > 0 {
                expiresAt = nowUs + UInt64(ttlHours * 3_600_000_000)
            } else {
                expiresAt = nil
            }

            let id = "dir-\(UUID().uuidString.prefix(8))"

            let directive = Directive(
                id: id,
                directiveType: directiveType,
                triggerPattern: trigger,
                actionDescription: action,
                priority: Int32(priority),
                createdAt: nowUs,
                expiresAt: expiresAt,
                isActive: true,
                executionCount: 0,
                lastTriggeredAt: nil,
                sourceContext: context
            )

            let effectiveUpsertFn: DirectiveMemoryStore.UpsertFn = upsertFn ?? { id, dirType, trig, act, pri, created, expires, ctx in
                try upsertDirective(
                    id: id, directiveType: dirType, triggerPattern: trig,
                    actionDescription: act, priority: pri,
                    createdAt: created, expiresAt: expires, sourceContext: ctx
                )
            }

            try DirectiveMemoryStore.save(directive, upsertFn: effectiveUpsertFn)

            var result: [String: Any] = [
                "result": "directive_created",
                "id": id,
                "type": directiveType,
                "trigger": trigger,
                "action": action,
                "priority": priority,
            ]
            if let expiresAt {
                result["expiresInHours"] = String(format: "%.1f", Double(expiresAt - nowUs) / 3_600_000_000.0)
            }
            return formatJSONLine(result)
        }

        return RegisteredTool(spec: spec, handler: handler)
    }

    // MARK: - get_directives

    /// List active directives.
    static func getDirectivesTool(
        queryFn: DirectiveMemoryStore.QueryActiveFn? = nil
    ) -> RegisteredTool {
        let spec = ToolSpec(
            name: "get_directives",
            description: "List active directives (reminders, automation triggers, watches). Returns all non-expired, active directives sorted by priority. Use this to check what persistent instructions are set up.",
            inputSchema: objectSchema(
                properties: [
                    "limit": prop("integer", "Maximum results (default 20, max 50)"),
                ],
                required: []
            )
        )

        let handler: AgentToolHandler = { args in
            let limit = try parseClampedInt(args, key: "limit", defaultValue: 20, min: 1, max: 50)

            let effectiveQueryFn: DirectiveMemoryStore.QueryActiveFn = queryFn ?? { nowUs, lim in
                try queryActiveDirectives(nowUs: nowUs, limit: lim)
            }

            let directives = try DirectiveMemoryStore.queryActive(
                limit: UInt32(limit),
                queryFn: effectiveQueryFn
            )

            if directives.isEmpty {
                return formatJSONLine(["result": "no_active_directives"])
            }

            return directives.prefix(limit).map { d in
                var fields: [String: Any] = [
                    "id": d.id,
                    "type": d.directiveType,
                    "trigger": d.triggerPattern,
                    "action": d.actionDescription,
                    "priority": d.priority,
                ]
                if d.executionCount > 0 { fields["executionCount"] = d.executionCount }
                if let expiresAt = d.expiresAt {
                    let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                    if expiresAt > nowUs {
                        let hoursLeft = Double(expiresAt - nowUs) / 3_600_000_000.0
                        fields["expiresInHours"] = String(format: "%.1f", hoursLeft)
                    }
                }
                if let lastTriggered = d.lastTriggeredAt { fields["lastTriggeredAt"] = lastTriggered }
                return formatJSONLine(fields)
            }.joined(separator: "\n")
        }

        return RegisteredTool(spec: spec, handler: handler)
    }
}
