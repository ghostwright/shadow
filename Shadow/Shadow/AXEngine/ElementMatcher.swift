@preconcurrency import ApplicationServices
import Foundation

// MARK: - Element Matching with Confidence Scoring

/// Match an element against criteria and return a scored result.
/// Uses a 5-level cascade adapted from AXorcist's matching system.
///
/// Levels:
/// 1. DOM ID (0.95) — highest confidence for web content
/// 2. AX Identifier (0.90) — native app element IDs
/// 3. Role + exact title (0.85)
/// 4. Query-based fuzzy match (0.70-0.80)
/// 5. Title contains match (0.60)
///
/// Boosts for editable fields (+0.05) and visible/on-screen elements (+0.02).
@MainActor
func matchElement(
    _ element: ShadowElement,
    role: String? = nil,
    title: String? = nil,
    identifier: String? = nil,
    domId: String? = nil,
    query: String? = nil,
    depth: Int = 0
) -> AXSearchResult? {
    // Role filter (if specified, must match exactly)
    if let role, element.role() != role { return nil }

    var bestConfidence: Double = 0
    var bestStrategy = ""

    // Level 1: DOM ID (highest confidence for web content)
    if let domId, let elDomId = element.domId(), elDomId == domId {
        bestConfidence = 0.95
        bestStrategy = "domId"
    }

    // Level 2: AX Identifier
    if bestConfidence < 0.90,
       let identifier, let elId = element.identifier(), elId == identifier {
        bestConfidence = 0.90
        bestStrategy = "identifier"
    }

    // Level 3: Role + exact title
    if bestConfidence < 0.85,
       let title, let elTitle = element.title(), elTitle == title {
        bestConfidence = 0.85
        bestStrategy = "role+title"
    }

    // Level 4: Query-based fuzzy match (from AXorcist's Element+Search.matches)
    if bestConfidence < 0.70, let query {
        let queryLower = query.lowercased()
        let candidates = [
            element.title(),
            element.value(),
            element.descriptionText(),
            element.placeholderValue(),
            element.identifier(),
            element.help(),
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for candidate in candidates {
            let candidateLower = candidate.lowercased()
            if candidateLower == queryLower {
                bestConfidence = max(bestConfidence, 0.80)
                bestStrategy = "exactQueryMatch"
            } else if candidateLower.contains(queryLower) {
                bestConfidence = max(bestConfidence, 0.70)
                bestStrategy = "containsQuery"
            } else if queryLower.contains(candidateLower) && candidateLower.count >= 2 {
                // Reverse containment: the query contains the element's text.
                // This handles cases like query="Compose button" matching element with title="Compose".
                // Also handles query="To recipients" matching element with title="To".
                // Require at least 2 chars to avoid matching single-letter elements.
                let ratio = Double(candidateLower.count) / Double(queryLower.count)
                let score = 0.55 + ratio * 0.15  // 0.55-0.70 based on match ratio
                bestConfidence = max(bestConfidence, score)
                bestStrategy = "reverseContains"
            }
        }
    }

    // Level 5: Title contains match
    if bestConfidence < 0.60,
       let title, let elTitle = element.title(),
       elTitle.lowercased().contains(title.lowercased()) {
        bestConfidence = 0.60
        bestStrategy = "titleContains"
    }

    guard bestConfidence > 0 else { return nil }

    // Boost for editable fields when searching for type targets
    // (from GhostOS's field scoring pattern)
    let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]
    if let r = element.role(), editableRoles.contains(r) {
        bestConfidence = min(bestConfidence + 0.05, 1.0)
    }

    // Boost for visible/on-screen elements
    if element.frame() != nil, !element.isHidden() {
        bestConfidence = min(bestConfidence + 0.02, 1.0)
    }

    return AXSearchResult(
        element: element,
        confidence: bestConfidence,
        matchStrategy: bestStrategy,
        semanticDepth: depth,
        realDepth: depth
    )
}
