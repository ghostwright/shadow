import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SafetyGate")

// MARK: - Safety Gate

/// LLM-based safety assessment for procedure steps before execution.
///
/// Two-tier safety model:
/// 1. **Hard rules** — instant, no LLM needed. These CANNOT be overridden by any
///    LLM output or user request. They represent absolute invariants.
/// 2. **LLM contextual assessment** — classifies risk as low/medium/high/critical
///    based on the action, target element, and application context.
///
/// Risk levels:
/// - `.low` — navigation, reading, scrolling. Auto-approved.
/// - `.medium` — form entry, file creation. Auto-approved with logging.
/// - `.high` — sending messages, financial actions. Requires user approval.
/// - `.critical` — deletion, admin actions. Requires user approval + confirmation.
/// - `.blocked` — hard rule violation. Cannot proceed.
///
/// Actor isolation ensures thread-safe assessment.
actor SafetyGate {

    private let llmProvider: (any LLMProvider)?

    init(llmProvider: (any LLMProvider)? = nil) {
        self.llmProvider = llmProvider
    }

    // MARK: - Hard Rules

    /// Constitutional rules that CANNOT be overridden by LLM or user.
    enum HardRule: String, CaseIterable, Sendable {
        /// Never automate password or secure text fields.
        case neverAutomateSecureFields
        /// Never automate biometric authentication prompts.
        case neverAutomateBiometrics
        /// Never modify system security settings (Gatekeeper, SIP, etc.)
        case neverModifySecuritySettings
        /// Never access Keychain or credential storage.
        case neverAccessKeychain
        /// Kill switch (Option+Escape) must always be active during execution.
        case killSwitchAlwaysActive

        var description: String {
            switch self {
            case .neverAutomateSecureFields: "Cannot automate secure text fields (passwords)"
            case .neverAutomateBiometrics: "Cannot automate biometric authentication"
            case .neverModifySecuritySettings: "Cannot modify system security settings"
            case .neverAccessKeychain: "Cannot access Keychain or credential storage"
            case .killSwitchAlwaysActive: "Kill switch must remain active"
            }
        }
    }

    /// Blocked element roles — actions on these are always denied.
    private static let blockedRoles: Set<String> = [
        "AXSecureTextField"
    ]

    /// Blocked app bundle IDs — never automate these.
    private static let blockedBundleIds: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.systempreferences"
    ]

    /// Blocked window title patterns (case-insensitive contains).
    private static let blockedTitlePatterns: [String] = [
        "keychain",
        "security & privacy",
        "privacy & security",
        "filevault",
        "gatekeeper"
    ]

    // MARK: - Assessment

    /// Assess a procedure before execution.
    ///
    /// Checks hard rules against the entire procedure, then uses LLM for
    /// contextual risk assessment if no hard rule violations are found.
    func assessProcedure(_ procedure: ProcedureTemplate) async -> SafetyAssessment {
        // Check if any steps target blocked apps
        if Self.blockedBundleIds.contains(procedure.sourceBundleId) {
            return SafetyAssessment(
                riskLevel: .blocked,
                rationale: "Procedure targets a restricted application: \(procedure.sourceApp)",
                requiresApproval: false
            )
        }

        // Check step action types for high-risk patterns
        var hasHighRiskSteps = false
        for step in procedure.steps {
            if case .typeText = step.actionType {
                // Typing is medium risk by default
                hasHighRiskSteps = true
            }
        }

        // If LLM is available, do contextual assessment
        if let llmProvider, llmProvider.isAvailable {
            return await llmContextualAssessment(procedure)
        }

        // Without LLM, use conservative heuristic
        let level: SafetyRiskLevel = hasHighRiskSteps ? .medium : .low
        return SafetyAssessment(
            riskLevel: level,
            rationale: "Heuristic assessment: \(procedure.steps.count) steps in \(procedure.sourceApp)",
            requiresApproval: level >= .high
        )
    }

    /// Assess a single action before execution.
    ///
    /// Phase 1: Hard rules (instant, no LLM).
    /// Phase 2: Read-only check.
    /// Phase 3: LLM contextual assessment.
    func assessAction(
        actionType: RecordedAction.ActionType,
        elementRole: String?,
        app: String,
        bundleId: String,
        windowTitle: String?
    ) async -> SafetyAssessment {
        // Phase 1: Hard rules
        if let violation = checkHardRules(
            elementRole: elementRole,
            bundleId: bundleId,
            windowTitle: windowTitle
        ) {
            return SafetyAssessment(
                riskLevel: .blocked,
                rationale: violation,
                requiresApproval: false
            )
        }

        // Phase 2: Read-only actions are always safe
        if isReadOnlyAction(actionType) {
            return SafetyAssessment(
                riskLevel: .low,
                rationale: "Read-only action",
                requiresApproval: false
            )
        }

        // Phase 3: LLM contextual assessment
        if let llmProvider, llmProvider.isAvailable {
            return await llmActionAssessment(
                actionType: actionType,
                elementRole: elementRole,
                app: app,
                windowTitle: windowTitle
            )
        }

        // Conservative fallback
        return SafetyAssessment(
            riskLevel: .medium,
            rationale: "No LLM available — default medium risk",
            requiresApproval: false
        )
    }

    // MARK: - Hard Rule Checks

    /// Check hard rules against element and context.
    /// Returns the violation description if any rule is violated, nil if all pass.
    func checkHardRules(
        elementRole: String?,
        bundleId: String,
        windowTitle: String?
    ) -> String? {
        // Rule: Never automate secure fields
        if let role = elementRole, Self.blockedRoles.contains(role) {
            return HardRule.neverAutomateSecureFields.description
        }

        // Rule: Never access Keychain
        if Self.blockedBundleIds.contains(bundleId) {
            return HardRule.neverAccessKeychain.description
        }

        // Rule: Never modify security settings
        if let title = windowTitle?.lowercased() {
            for pattern in Self.blockedTitlePatterns {
                if title.contains(pattern) {
                    return HardRule.neverModifySecuritySettings.description
                }
            }
        }

        return nil
    }

    // MARK: - Read-Only Classification

    /// Determine if an action is read-only (no side effects).
    func isReadOnlyAction(_ actionType: RecordedAction.ActionType) -> Bool {
        switch actionType {
        case .scroll: return true
        case .appSwitch: return true
        case .click, .typeText, .keyPress: return false
        }
    }

    // MARK: - LLM Assessment

    /// LLM-based contextual risk assessment for a procedure.
    private func llmContextualAssessment(
        _ procedure: ProcedureTemplate
    ) async -> SafetyAssessment {
        guard let llmProvider else {
            return SafetyAssessment(riskLevel: .medium, rationale: "No LLM", requiresApproval: false)
        }

        let stepDescriptions = procedure.steps.map { step in
            "\(step.index + 1). \(step.intent) (\(describeActionType(step.actionType)))"
        }.joined(separator: "\n")

        let prompt = """
        Assess the safety risk of this automated procedure on macOS:

        Procedure: \(procedure.name)
        Description: \(procedure.description)
        Application: \(procedure.sourceApp) (\(procedure.sourceBundleId))
        Steps:
        \(stepDescriptions)

        Classify the overall risk as one of:
        - "low": navigation, reading, scrolling, app switching
        - "medium": form entry, file creation, non-destructive edits
        - "high": sending messages, financial transactions, publishing
        - "critical": deletion, admin actions, irreversible operations

        Respond with JSON:
        {"riskLevel": "...", "rationale": "...", "requiresApproval": true/false}
        """

        let request = LLMRequest(
            systemPrompt: "You are a safety classifier for automated macOS procedures. Be concise.",
            userPrompt: prompt,
            maxTokens: 300,
            temperature: 0.1,
            responseFormat: .json
        )

        do {
            let response = try await llmProvider.generate(request: request)
            return parseSafetyResponse(response.content)
        } catch {
            logger.warning("LLM safety assessment failed: \(error.localizedDescription)")
            return SafetyAssessment(
                riskLevel: .medium,
                rationale: "LLM assessment failed — defaulting to medium risk",
                requiresApproval: false
            )
        }
    }

    /// LLM-based risk assessment for a single action.
    private func llmActionAssessment(
        actionType: RecordedAction.ActionType,
        elementRole: String?,
        app: String,
        windowTitle: String?
    ) async -> SafetyAssessment {
        guard let llmProvider else {
            return SafetyAssessment(riskLevel: .medium, rationale: "No LLM", requiresApproval: false)
        }

        let prompt = """
        Assess the risk of this computer action:
        - Action: \(describeActionType(actionType))
        - Target element role: \(elementRole ?? "unknown")
        - Application: \(app)
        - Window: \(windowTitle ?? "N/A")

        Classify as: low (navigation, read), medium (form entry, file creation),
        high (sending messages, financial), critical (deletion, admin actions).

        Respond with JSON:
        {"riskLevel": "...", "rationale": "...", "requiresApproval": true/false}
        """

        let request = LLMRequest(
            systemPrompt: "You are a safety classifier for automated macOS actions. Be concise.",
            userPrompt: prompt,
            maxTokens: 200,
            temperature: 0.1,
            responseFormat: .json
        )

        do {
            let response = try await llmProvider.generate(request: request)
            return parseSafetyResponse(response.content)
        } catch {
            return SafetyAssessment(
                riskLevel: .medium,
                rationale: "LLM failed — default medium",
                requiresApproval: false
            )
        }
    }

    // MARK: - Response Parsing

    /// Parse the LLM safety assessment response.
    private func parseSafetyResponse(_ content: String) -> SafetyAssessment {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SafetyAssessment(
                riskLevel: .medium,
                rationale: "Could not parse LLM response",
                requiresApproval: false
            )
        }

        let levelStr = json["riskLevel"] as? String ?? "medium"
        let rationale = json["rationale"] as? String ?? ""
        let requiresApproval = json["requiresApproval"] as? Bool ?? (levelStr == "high" || levelStr == "critical")

        let level: SafetyRiskLevel
        switch levelStr.lowercased() {
        case "low": level = .low
        case "medium": level = .medium
        case "high": level = .high
        case "critical": level = .critical
        default: level = .medium
        }

        return SafetyAssessment(
            riskLevel: level,
            rationale: rationale,
            requiresApproval: requiresApproval
        )
    }

    // MARK: - Helpers

    /// Describe an action type in natural language.
    private func describeActionType(_ actionType: RecordedAction.ActionType) -> String {
        switch actionType {
        case .click(let x, let y, let button, let count):
            let clickDesc = count > 1 ? "\(count)x \(button) click" : "\(button) click"
            return "\(clickDesc) at (\(Int(x)), \(Int(y)))"
        case .typeText(let text):
            let truncated = String(text.prefix(30))
            return "Type '\(truncated)\(text.count > 30 ? "..." : "")'"
        case .keyPress(_, let keyName, let modifiers):
            if modifiers.isEmpty { return "Press \(keyName)" }
            return "Press \(modifiers.joined(separator: "+"))+\(keyName)"
        case .appSwitch(let toApp, _):
            return "Switch to \(toApp)"
        case .scroll(_, let deltaY, _, _):
            return "Scroll \(deltaY > 0 ? "up" : "down")"
        }
    }
}

// MARK: - Safety Types

/// Risk level classification for an action or procedure.
enum SafetyRiskLevel: String, Codable, Sendable, Comparable {
    case low
    case medium
    case high
    case critical
    case blocked

    private var sortOrder: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        case .blocked: 4
        }
    }

    static func < (lhs: SafetyRiskLevel, rhs: SafetyRiskLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// Result of a safety assessment.
struct SafetyAssessment: Sendable {
    let riskLevel: SafetyRiskLevel
    let rationale: String
    let requiresApproval: Bool

    init(riskLevel: SafetyRiskLevel, rationale: String, requiresApproval: Bool = false) {
        self.riskLevel = riskLevel
        self.rationale = rationale
        self.requiresApproval = requiresApproval || riskLevel >= .high
    }
}
