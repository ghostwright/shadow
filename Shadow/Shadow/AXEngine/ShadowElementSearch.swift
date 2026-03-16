@preconcurrency import ApplicationServices
import Foundation
import os.log

private let searchLogger = Logger(subsystem: "com.shadow.app", category: "AXSearch")

// MARK: - Role Classification

/// Roles that are semantic containers — traversal costs 1 depth unit.
private let semanticRoles: Set<String> = [
    "AXApplication", "AXWindow", "AXToolbar", "AXMenuBar", "AXMenu",
    "AXMenuItem", "AXSheet", "AXDialog", "AXPopover", "AXDrawer",
    "AXWebArea", "AXTable", "AXOutline", "AXBrowser", "AXTabGroup",
    "AXSplitGroup", "AXScrollArea"
]

/// Roles that are layout wrappers — traversal costs 0 depth units.
/// This is the key insight from GhostOS's semantic depth tunneling.
private let layoutRoles: Set<String> = [
    "AXGroup", "AXGenericElement", "AXSection", "AXDiv", "AXList",
    "AXLandmarkMain", "AXLandmarkNavigation", "AXLandmarkBanner",
    "AXLandmarkContentInfo", "AXLandmarkSearch", "AXLandmarkComplementary",
    "AXLayoutArea", "AXLayoutItem", "AXSplitter", "AXUnknown"
]

/// Combined: all roles that can have meaningful descendants.
private let containerRoles: Set<String> = semanticRoles.union(layoutRoles)

// MARK: - Search Result

/// Result from a tree search with confidence scoring.
struct AXSearchResult: Sendable {
    let element: ShadowElement
    let confidence: Double  // 0.0 - 1.0
    let matchStrategy: String
    let semanticDepth: Int
    let realDepth: Int
}

// MARK: - Tree Walk Action

enum TreeWalkAction {
    case `continue`
    case skipChildren
    case stop
}

// MARK: - Tree Walker

/// Tree walker with cycle detection, depth limiting, timeout, and semantic tunneling.
@MainActor
func walkTree(
    root: ShadowElement,
    maxSemanticDepth: Int = 25,
    maxRealDepth: Int = 50,
    timeoutSeconds: TimeInterval = 15,
    visitor: (ShadowElement, Int) -> TreeWalkAction
) {
    var visited = Set<UInt>()
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var timedOut = false

    func walk(_ el: ShadowElement, semanticDepth: Int, realDepth: Int) {
        // Timeout check
        guard !timedOut else { return }
        if Date() >= deadline {
            timedOut = true
            return
        }

        // Cycle detection
        guard visited.insert(el.cfHash).inserted else { return }

        // Depth check
        guard semanticDepth <= maxSemanticDepth, realDepth <= maxRealDepth else { return }

        // Visit
        let action = visitor(el, semanticDepth)
        switch action {
        case .stop: timedOut = true; return
        case .skipChildren: return
        case .continue: break
        }

        // Get children
        let role = el.role() ?? ""
        guard containerRoles.contains(role) || realDepth == 0 else { return }

        let children = el.allChildren(maxCount: 5000)
        let depthCost = layoutRoles.contains(role) ? 0 : 1

        for child in children {
            guard !timedOut else { return }
            walk(child,
                 semanticDepth: semanticDepth + depthCost,
                 realDepth: realDepth + 1)
        }
    }

    walk(root, semanticDepth: 0, realDepth: 0)
}

// MARK: - Element Finding

/// Find elements matching criteria within an app's AX tree.
@MainActor
func findElements(
    in app: ShadowElement,
    role: String? = nil,
    title: String? = nil,
    identifier: String? = nil,
    domId: String? = nil,
    query: String? = nil,
    maxResults: Int = 10,
    maxDepth: Int = 25,
    timeout: TimeInterval = 10
) -> [AXSearchResult] {
    var results: [AXSearchResult] = []

    // Content-root-first strategy (from GhostOS):
    // For web apps, search AXWebArea subtree first, then full app tree.
    let startElement: ShadowElement
    if let window = app.focusedWindow(),
       let webArea = findWebArea(in: window) {
        startElement = webArea
    } else if let window = app.focusedWindow() {
        startElement = window
    } else {
        startElement = app
    }

    walkTree(root: startElement, maxSemanticDepth: maxDepth, timeoutSeconds: timeout) { element, depth in
        if results.count >= maxResults { return .stop }

        if let match = matchElement(
            element,
            role: role, title: title, identifier: identifier,
            domId: domId, query: query, depth: depth
        ) {
            results.append(match)
        }
        return .continue
    }

    return results.sorted { $0.confidence > $1.confidence }
}

/// Find the AXWebArea element within a window (for content-root-first search).
@MainActor
private func findWebArea(in window: ShadowElement) -> ShadowElement? {
    var found: ShadowElement?
    walkTree(root: window, maxSemanticDepth: 5, timeoutSeconds: 2) { el, _ in
        if el.role() == "AXWebArea" {
            found = el
            return .stop
        }
        return .continue
    }
    return found
}

/// Collect all interactive elements in a tree (buttons, fields, links, etc.)
@MainActor
func collectInteractiveElements(
    in root: ShadowElement,
    maxDepth: Int = 15,
    maxCount: Int = 200,
    timeout: TimeInterval = 0.5
) -> [ShadowElement] {
    let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXComboBox",
        "AXSearchField", "AXCheckBox", "AXRadioButton", "AXSlider",
        "AXPopUpButton", "AXMenuButton", "AXLink", "AXStaticText",
        "AXImage", "AXSwitch", "AXStepper", "AXDateField",
        "AXColorWell", "AXCell", "AXRow", "AXMenuItem",
        "AXTab", "AXDisclosureTriangle", "AXSecureTextField"
    ]

    var results: [ShadowElement] = []

    walkTree(root: root, maxSemanticDepth: maxDepth, timeoutSeconds: timeout) { element, _ in
        if results.count >= maxCount { return .stop }

        if let role = element.role(), interactiveRoles.contains(role) {
            results.append(element)
        }
        return .continue
    }

    return results
}
