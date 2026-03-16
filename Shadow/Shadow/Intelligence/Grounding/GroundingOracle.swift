import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "GroundingOracle")

/// The central element resolution engine for the Mimicry system.
///
/// Implements a multi-strategy grounding cascade:
///   1. **AX tree search** (0ms, instant) -- Search the AX tree by role + title + identifier.
///      Covers 70-80% of interactions. Free and instant.
///   2. **AX fuzzy matching** (~10ms) -- Relaxed search: partial title match, description match,
///      identifier-only match. Covers another 10%.
///   3. **Local VLM grounding** (~300ms) -- Take a live screenshot, run ShowUI-2B locally.
///      Covers the remaining 10-20% (poor AX trees, unlabeled elements).
///   4. **Cloud escalation** (~2s) -- Send screenshot to cloud VLM for higher accuracy.
///      Only when local VLM confidence is too low.
///
/// For the vast majority of actions, grounding is FREE (AX tree) and instant.
/// The VLM is only invoked when accessibility metadata is insufficient.
///
/// Mimicry Phase B: AX-First, Vision-Fallback Grounding Strategy.
actor GroundingOracle {

    /// The local grounding model (ShowUI-2B on MLX).
    private let groundingModel: LocalGroundingModel?

    /// Vision LLM provider for cloud-escalation-like fallback (uses on-device Qwen2.5-VL-7B).
    private let visionProvider: VisionLLMProvider?

    /// Minimum confidence threshold for AX tree matches.
    private static let axConfidenceThreshold: Double = 0.40

    /// Minimum confidence threshold for VLM grounding before escalating.
    private static let vlmConfidenceThreshold: Double = 0.30

    /// Total grounding attempts this session (diagnostics).
    private(set) var totalAttempts: Int = 0

    /// Counts by strategy (for diagnostics and optimization).
    private(set) var axHits: Int = 0
    private(set) var axFuzzyHits: Int = 0
    private(set) var vlmHits: Int = 0
    private(set) var escalationHits: Int = 0
    private(set) var misses: Int = 0

    // MARK: - Init

    init(
        groundingModel: LocalGroundingModel? = nil,
        visionProvider: VisionLLMProvider? = nil
    ) {
        self.groundingModel = groundingModel
        self.visionProvider = visionProvider
    }

    // MARK: - Grounding

    /// Find a UI element matching the given description.
    ///
    /// Uses the multi-strategy cascade: AX exact -> AX fuzzy -> VLM -> escalation.
    /// Returns the best match found across all strategies, or nil if nothing found.
    ///
    /// - Parameters:
    ///   - description: Natural language or structured description of the target element
    ///     (e.g., "Compose button", "AXButton titled Send", "search field")
    ///   - role: Optional AX role filter (e.g., "AXButton")
    ///   - title: Optional exact title to match
    ///   - identifier: Optional AX identifier to match
    ///   - app: The application element to search in
    ///   - screenshot: Optional screenshot for VLM grounding (captured lazily if needed)
    ///   - screenSize: Logical screen size for coordinate mapping
    /// - Returns: A `GroundingMatch` with the found element and strategy used, or nil
    func findElement(
        description: String,
        role: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        in app: ShadowElement,
        screenshot: CGImage? = nil,
        screenSize: CGSize? = nil
    ) async -> GroundingMatch? {
        totalAttempts += 1
        let startTime = CFAbsoluteTimeGetCurrent()
        let cleanDesc = Self.extractCleanLabel(from: description)
        logger.notice("[MIMICRY] Grounding: searching for '\(cleanDesc, privacy: .public)' (raw: '\(description, privacy: .public)') role=\(role ?? "nil", privacy: .public) VLM=\(self.groundingModel != nil ? (self.groundingModel!.isAvailable ? "READY" : "not-available") : "nil", privacy: .public)")

        // Resolve screen size on MainActor if not provided
        let resolvedScreenSize = await MainActor.run {
            screenSize ?? NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        }

        // Strategy 1: AX tree exact search (dispatched to MainActor for AX calls)
        if let axMatch = await axExactSearch(
            role: role, title: title, identifier: identifier,
            description: description, in: app
        ) {
            axHits += 1
            DiagnosticsStore.shared.increment("grounding_ax_hit_total")
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.notice("[MIMICRY] Grounding: AX EXACT match for '\(description, privacy: .public)' in \(String(format: "%.1f", elapsed))ms")
            return axMatch
        }

        // Strategy 2: AX tree fuzzy search
        if let fuzzyMatch = await axFuzzySearch(
            description: description, role: role, in: app
        ) {
            axFuzzyHits += 1
            DiagnosticsStore.shared.increment("grounding_ax_fuzzy_hit_total")
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.notice("[MIMICRY] Grounding: AX FUZZY match for '\(description, privacy: .public)' in \(String(format: "%.1f", elapsed))ms")
            return fuzzyMatch
        }

        // Strategy 3: Local VLM grounding (if model available and screenshot provided/capturable)
        if let groundingModel, groundingModel.isAvailable {
            let image: CGImage?
            if let screenshot {
                image = screenshot
            } else {
                image = await captureScreenshot()
            }
            if let image {
                do {
                    let result = try await groundingModel.ground(
                        instruction: description,
                        screenshot: image,
                        screenSize: resolvedScreenSize
                    )

                    if result.confidence >= Self.vlmConfidenceThreshold {
                        // Try to find an AX element at the predicted coordinates
                        let elementAtPoint = await MainActor.run {
                            ShadowElement.atPoint(result.point)
                        }
                        if let element = elementAtPoint {
                            vlmHits += 1
                            DiagnosticsStore.shared.increment("grounding_vlm_hit_total")
                            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                            logger.notice("[MIMICRY] Grounding: VLM match for '\(description, privacy: .public)' at (\(String(format: "%.0f", result.x)), \(String(format: "%.0f", result.y))) conf=\(String(format: "%.2f", result.confidence)) in \(String(format: "%.0f", elapsed))ms")
                            return GroundingMatch(
                                element: element,
                                confidence: result.confidence,
                                strategy: .vlmGrounding,
                                point: result.point
                            )
                        }

                        // No AX element at those coordinates -- return coordinate-only match
                        vlmHits += 1
                        DiagnosticsStore.shared.increment("grounding_vlm_coord_hit_total")
                        return GroundingMatch(
                            element: nil,
                            confidence: result.confidence * 0.8,
                            strategy: .vlmCoordinateOnly,
                            point: result.point
                        )
                    }
                } catch {
                    logger.warning("VLM grounding failed: \(error, privacy: .public)")
                }
            }
        }

        // Strategy 4: Cloud/Vision escalation (uses on-device Qwen2.5-VL-7B if available)
        if let visionProvider, visionProvider.isAvailable {
            let image: CGImage?
            if let screenshot {
                image = screenshot
            } else {
                image = await captureScreenshot()
            }
            if let image {
                do {
                    let response = try await visionProvider.analyze(
                        image: image,
                        query: "Find the UI element described as: \"\(description)\". Return the coordinates as click(x=<X>, y=<Y>) where X and Y are pixel coordinates."
                    )

                    if let point = parseVisionResponse(response, screenSize: resolvedScreenSize) {
                        let elementAtPoint = await MainActor.run {
                            ShadowElement.atPoint(point)
                        }
                        if let element = elementAtPoint {
                            escalationHits += 1
                            DiagnosticsStore.shared.increment("grounding_escalation_hit_total")
                            return GroundingMatch(
                                element: element,
                                confidence: 0.6,
                                strategy: .visionEscalation,
                                point: point
                            )
                        }

                        return GroundingMatch(
                            element: nil,
                            confidence: 0.5,
                            strategy: .visionEscalation,
                            point: point
                        )
                    }
                } catch {
                    logger.warning("Vision escalation failed: \(error, privacy: .public)")
                }
            }
        }

        // All strategies exhausted
        misses += 1
        DiagnosticsStore.shared.increment("grounding_miss_total")
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.notice("[MIMICRY] Grounding: MISS for '\(description, privacy: .public)' — all 4 strategies failed (\(String(format: "%.0f", elapsed))ms). VLM model=\(self.groundingModel != nil ? "loaded" : "nil", privacy: .public), isAvailable=\(self.groundingModel?.isAvailable == true ? "yes" : "no", privacy: .public)")
        return nil
    }

    /// Diagnostics summary of grounding strategy distribution.
    var diagnosticsSummary: String {
        let total = max(totalAttempts, 1)
        return """
        Grounding Oracle: \(totalAttempts) attempts
        - AX exact: \(axHits) (\(axHits * 100 / total)%)
        - AX fuzzy: \(axFuzzyHits) (\(axFuzzyHits * 100 / total)%)
        - VLM: \(vlmHits) (\(vlmHits * 100 / total)%)
        - Escalation: \(escalationHits) (\(escalationHits * 100 / total)%)
        - Misses: \(misses) (\(misses * 100 / total)%)
        """
    }

    // MARK: - Strategy 1: AX Exact Search

    private func axExactSearch(
        role: String?,
        title: String?,
        identifier: String?,
        description: String,
        in app: ShadowElement
    ) async -> GroundingMatch? {
        let cleanTitle = title ?? Self.extractCleanLabel(from: description)

        let results = await MainActor.run {
            findElements(
                in: app,
                role: role,
                title: cleanTitle,
                identifier: identifier,
                domId: nil,
                maxResults: 5,
                timeout: 2.0
            )
        }

        if let best = results.first, best.confidence >= Self.axConfidenceThreshold {
            let center = await MainActor.run { centerPoint(of: best.element) }
            logger.info("AX exact: found '\(cleanTitle, privacy: .public)' via \(best.matchStrategy, privacy: .public) conf=\(String(format: "%.2f", best.confidence))")
            return GroundingMatch(
                element: best.element,
                confidence: best.confidence,
                strategy: .axExact,
                point: center
            )
        }

        // If role-filtered search failed, retry without role filter (web apps have wrong roles)
        if role != nil {
            let noRoleResults = await MainActor.run {
                findElements(
                    in: app,
                    role: nil,
                    title: cleanTitle,
                    identifier: identifier,
                    domId: nil,
                    maxResults: 5,
                    timeout: 2.0
                )
            }

            if let best = noRoleResults.first, best.confidence >= Self.axConfidenceThreshold {
                let center = await MainActor.run { centerPoint(of: best.element) }
                logger.info("AX exact (role-relaxed): found '\(cleanTitle, privacy: .public)' via \(best.matchStrategy, privacy: .public) conf=\(String(format: "%.2f", best.confidence))")
                return GroundingMatch(
                    element: best.element,
                    confidence: best.confidence,
                    strategy: .axExact,
                    point: center
                )
            }
        }

        return nil
    }

    // MARK: - Strategy 2: AX Fuzzy Search

    private func axFuzzySearch(
        description: String,
        role: String?,
        in app: ShadowElement
    ) async -> GroundingMatch? {
        // Extract clean label text — strip AX role prefixes like "AXButton titled 'Compose'"
        let cleanQuery = Self.extractCleanLabel(from: description)

        let results = await MainActor.run {
            findElements(
                in: app,
                role: nil,
                query: cleanQuery,
                maxResults: 10,
                maxDepth: 25,
                timeout: 5.0
            )
        }

        if let best = results.first, best.confidence >= (Self.axConfidenceThreshold * 0.8) {
            let center = await MainActor.run { centerPoint(of: best.element) }
            logger.info("AX fuzzy: found '\(cleanQuery, privacy: .public)' via \(best.matchStrategy, privacy: .public) conf=\(String(format: "%.2f", best.confidence))")
            return GroundingMatch(
                element: best.element,
                confidence: best.confidence * 0.9,
                strategy: .axFuzzy,
                point: center
            )
        }

        return nil
    }

    // MARK: - Description Cleaning

    /// Extract the clean visible label from a description that may contain AX role prefixes.
    ///
    /// Input patterns handled:
    ///   "AXButton titled 'Compose'"               -> "Compose"
    ///   "AXButton titled \u{2018}Compose\u{2019}"  -> "Compose"  (smart quotes)
    ///   "AXTextField for 'To'"                     -> "To"
    ///   "AXTextField for 'To' recipients in ..."   -> "To"
    ///   "AXTextArea for email body in ..."          -> "email body"
    ///   "Compose button"                            -> "Compose button"
    ///   "Compose"                                   -> "Compose"
    static func extractCleanLabel(from description: String) -> String {
        // Step 1: Normalize smart/curly quotes to ASCII equivalents.
        // LLMs frequently emit Unicode curly quotes (\u2018/\u2019/\u201C/\u201D)
        // which our regex character classes need to match.
        let normalized = description
            .replacingOccurrences(of: "\u{2018}", with: "'")   // left single smart quote
            .replacingOccurrences(of: "\u{2019}", with: "'")   // right single smart quote
            .replacingOccurrences(of: "\u{201C}", with: "\"")  // left double smart quote
            .replacingOccurrences(of: "\u{201D}", with: "\"")  // right double smart quote

        // Pattern: "AXRole titled 'Label'" or "AXRole titled \"Label\""
        if let match = normalized.firstMatch(
            of: /AX\w+\s+titled\s+['"](.+?)['"]/
        ) {
            return String(match.1)
        }

        // Pattern: "AXRole for 'Label'" or "AXRole for \"Label\""
        // Note: only extract up to the closing quote, NOT trailing qualifiers
        // like "in compose window" or "recipients"
        if let match = normalized.firstMatch(
            of: /AX\w+\s+for\s+['"](.+?)['"]/
        ) {
            return String(match.1)
        }

        // Pattern: "AXRole for Label" (no quotes) — extract just the first phrase
        // "AXTextField for To recipients in compose window" -> "To"
        // "AXTextArea for email body in compose window" -> "email body"
        // Strategy: take everything after "for ", then strip trailing qualifiers
        // ("in ...", "of ...", "recipients", "field", "area", "button", etc.)
        if let match = normalized.firstMatch(
            of: /AX\w+\s+for\s+(.+)/
        ) {
            let raw = String(match.1).trimmingCharacters(in: .whitespaces)
            return stripTrailingQualifiers(raw)
        }

        // Pattern: "AXRole titled Label" (no quotes) — same cleanup
        if let match = normalized.firstMatch(
            of: /AX\w+\s+titled\s+(.+)/
        ) {
            let raw = String(match.1).trimmingCharacters(in: .whitespaces)
            return stripTrailingQualifiers(raw)
        }

        // Pattern: "AXRole 'Label'" (no "titled"/"for" keyword, just AX prefix + quoted label)
        // Handles: "AXTextField 'To'" -> "To", "AXButton 'Send'" -> "Send"
        if let match = normalized.firstMatch(
            of: /AX\w+\s+['"](.+?)['"]/
        ) {
            return String(match.1)
        }

        // No AX prefix — return as-is
        return normalized
    }

    /// Strip trailing qualifiers from a label extracted from an AX description.
    ///
    /// Examples:
    ///   "'To' recipients in compose window" -> "To"
    ///   "email body in compose window"      -> "email body"
    ///   "Subject"                           -> "Subject"
    private static func stripTrailingQualifiers(_ raw: String) -> String {
        var label = raw

        // Remove leading/trailing quotes
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))

        // Remove trailing "in ..." clause (common in planner descriptions)
        if let inRange = label.range(
            of: #"\s+in\s+\w"#, options: .regularExpression
        ) {
            label = String(label[label.startIndex..<inRange.lowerBound])
        }

        // Remove trailing generic qualifiers (UI chrome terms, NOT domain labels).
        // Note: " recipients" is intentionally excluded — it's a valid label
        // component in Gmail's "To recipients" combobox.
        let qualifiers = [" field", " area", " button", " input",
                          " compose window", " window", " dialog", " panel"]
        for q in qualifiers {
            if label.lowercased().hasSuffix(q) {
                label = String(label.dropLast(q.count))
            }
        }

        return label.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Screenshot Capture

    /// Capture the current screen for VLM grounding.
    @MainActor
    private func captureScreenshot() -> CGImage? {
        guard let screen = NSScreen.main else { return nil }
        let screenRect = CGRect(
            x: 0, y: 0,
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
        return CGWindowListCreateImage(
            screenRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        )
    }

    // MARK: - Geometry Helpers

    /// Compute the center point of an AX element (position + size/2).
    ///
    /// `ShadowElement.position()` returns the top-left corner, but clicks
    /// need to target the center for reliable hit-testing. Returns nil if
    /// position or size is unavailable.
    @MainActor
    private func centerPoint(of element: ShadowElement) -> CGPoint? {
        guard let pos = element.position(), let sz = element.size() else {
            return element.position()  // fallback to top-left if size unavailable
        }
        return CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
    }

    // MARK: - Vision Response Parsing

    /// Parse a vision model response to extract coordinates.
    private func parseVisionResponse(
        _ response: String,
        screenSize: CGSize
    ) -> CGPoint? {
        // Try click(x=N, y=N) format
        if let match = response.firstMatch(of: /click\(\s*x\s*=\s*([\d.]+)\s*,\s*y\s*=\s*([\d.]+)\s*\)/) {
            if let x = Double(match.1), let y = Double(match.2) {
                if x <= 1.0 && y <= 1.0 {
                    return CGPoint(x: x * screenSize.width, y: y * screenSize.height)
                }
                return CGPoint(x: x, y: y)
            }
        }

        // Try (N, N) format
        if let match = response.firstMatch(of: /\(\s*([\d.]+)\s*,\s*([\d.]+)\s*\)/) {
            if let x = Double(match.1), let y = Double(match.2) {
                if x <= 1.0 && y <= 1.0 {
                    return CGPoint(x: x * screenSize.width, y: y * screenSize.height)
                }
                return CGPoint(x: x, y: y)
            }
        }

        return nil
    }
}

// MARK: - Match Type

/// Result of a grounding attempt.
struct GroundingMatch: Sendable {
    /// The found AX element (nil if only coordinates were found via VLM).
    let element: ShadowElement?
    /// Confidence score (0.0-1.0).
    let confidence: Double
    /// Which strategy found the match.
    let strategy: GroundingStrategy
    /// Screen coordinates of the matched element.
    let point: CGPoint?
}

/// Which grounding strategy produced a match.
enum GroundingStrategy: String, Sendable {
    /// AX tree exact match (role + title + identifier).
    case axExact
    /// AX tree fuzzy match (partial title, description, broader search).
    case axFuzzy
    /// Local VLM grounding (ShowUI-2B), with AX element at predicted coordinates.
    case vlmGrounding
    /// Local VLM grounding, coordinate-only (no AX element at predicted point).
    case vlmCoordinateOnly
    /// Vision model escalation (larger VLM for complex UIs).
    case visionEscalation
}
