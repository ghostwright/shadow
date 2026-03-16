@preconcurrency import ApplicationServices
import Foundation

// MARK: - Element Locator

/// Describes how to find a UI element for procedure replay.
/// Stores multiple resolution strategies with fallback priorities.
///
/// The 5-level resolution cascade:
/// 1. DOM ID (web content)
/// 2. AX Identifier (native elements)
/// 3. Role + exact title
/// 4. Path hints (ancestor chain)
/// 5. Position fallback (last resort)
struct ElementLocator: Codable, Sendable {
    let role: String
    let title: String?
    let identifier: String?
    let domId: String?
    let domClass: String?
    let value: String?
    let pathHints: [PathHint]
    let positionFallback: CGPoint?

    /// Ancestor chain for disambiguation when multiple elements share a title.
    struct PathHint: Codable, Sendable {
        let role: String
        let childIndex: Int
        let title: String?
        let identifier: String?
    }

    /// Build a locator from a live element by capturing its identifying attributes.
    @MainActor
    static func from(_ element: ShadowElement, includePathHints: Bool = true) -> ElementLocator {
        let role = element.role() ?? "AXUnknown"
        let title = element.title()
        let identifier = element.identifier()
        let domId = element.domId()
        let domClass = element.domClassList()
        let value = element.value().map { String($0.prefix(100)) }
        let position = element.position()

        var pathHints: [PathHint] = []
        if includePathHints {
            pathHints = buildPathHints(for: element, maxAncestors: 5)
        }

        return ElementLocator(
            role: role,
            title: title,
            identifier: identifier,
            domId: domId,
            domClass: domClass,
            value: value,
            pathHints: pathHints,
            positionFallback: position
        )
    }

    /// Build ancestor path hints for disambiguation.
    @MainActor
    private static func buildPathHints(for element: ShadowElement, maxAncestors: Int) -> [PathHint] {
        var hints: [PathHint] = []
        var current = element
        var depth = 0

        while depth < maxAncestors {
            guard let parent = current.parent() else { break }

            // Find this element's index among its parent's children
            let siblings = parent.children()
            let index = siblings.firstIndex(of: current) ?? 0

            hints.append(PathHint(
                role: parent.role() ?? "AXUnknown",
                childIndex: index,
                title: parent.title(),
                identifier: parent.identifier()
            ))

            current = parent
            depth += 1
        }

        return hints
    }
}

// MARK: - CGPoint Codable Conformance

extension CGPoint: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case x, y
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(CGFloat.self, forKey: .x)
        let y = try container.decode(CGFloat.self, forKey: .y)
        self.init(x: x, y: y)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }
}

// MARK: - Locator Resolution

/// Resolve an ElementLocator against a live AX tree.
/// Returns the best match with confidence score.
/// Uses the 5-level cascade: domId > identifier > role+title > pathHints > position.
@MainActor
func resolveLocator(
    _ locator: ElementLocator,
    in app: ShadowElement,
    timeout: TimeInterval = 5
) -> AXSearchResult? {
    // Try direct element search with all available criteria
    let results = findElements(
        in: app,
        role: locator.role,
        title: locator.title,
        identifier: locator.identifier,
        domId: locator.domId,
        maxResults: 5,
        timeout: timeout
    )

    if let best = results.first, best.confidence >= 0.40 {
        return best
    }

    // Path hint navigation as fallback
    if !locator.pathHints.isEmpty {
        if let pathResult = resolveViaPath(locator.pathHints, in: app) {
            return pathResult
        }
    }

    // Position fallback (last resort)
    if let pos = locator.positionFallback {
        if let el = ShadowElement.atPoint(pos) {
            let elRole = el.role() ?? ""
            if elRole == locator.role {
                return AXSearchResult(
                    element: el,
                    confidence: 0.35,
                    matchStrategy: "positionFallback",
                    semanticDepth: 0,
                    realDepth: 0
                )
            }
        }
    }

    return nil
}

/// Navigate path hints to find an element.
@MainActor
private func resolveViaPath(_ hints: [ElementLocator.PathHint], in app: ShadowElement) -> AXSearchResult? {
    // Path hints are stored bottom-up (closest ancestor first).
    // Navigate top-down by reversing.
    let reversedHints = hints.reversed()

    var current: ShadowElement
    if let window = app.focusedWindow() {
        current = window
    } else {
        current = app
    }

    for hint in reversedHints {
        let children = current.children()
        // Try to find the child matching this hint
        if hint.childIndex < children.count {
            let candidate = children[hint.childIndex]
            if candidate.role() == hint.role {
                current = candidate
                continue
            }
        }
        // Fallback: search children for matching role+title
        if let match = children.first(where: {
            $0.role() == hint.role &&
            (hint.title == nil || $0.title() == hint.title)
        }) {
            current = match
        } else {
            // Path hint failed at this level — return best effort
            break
        }
    }

    return AXSearchResult(
        element: current,
        confidence: 0.50,
        matchStrategy: "pathHint",
        semanticDepth: 0,
        realDepth: 0
    )
}
