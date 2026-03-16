import Foundation
import os.log

private let captureLogger = Logger(subsystem: "com.shadow.app", category: "AXTreeCapture")

// MARK: - Snapshot Data Types

/// Serialized representation of an AX tree node for storage in the event log.
struct AXNodeSnapshot: Codable, Sendable {
    let nodeId: UInt32
    let parentId: UInt32?
    let role: String
    let subrole: String?
    let title: String?
    let value: String?  // truncated to 200 chars
    let identifier: String?
    let description: String?
    let enabled: Bool
    let focused: Bool
    let posX: Float?
    let posY: Float?
    let width: Float?
    let height: Float?
    let actions: [String]
    let domId: String?
    let domClassList: String?
}

/// Serialized AX tree snapshot for the event log.
struct AXTreeSnapshotData: Codable, Sendable {
    let timestampUs: UInt64
    let appBundleId: String
    let appName: String
    let windowTitle: String?
    let displayId: UInt32?
    let treeHash: UInt64
    let nodeCount: Int
    let nodes: [AXNodeSnapshot]
}

// MARK: - FNV-1a Tree Hash

/// Compute an FNV-1a hash over a sequence of AX node attributes for deduplication.
/// Includes role, title, and value prefix (first 50 chars) for change detection.
func computeTreeHash(_ nodes: [AXNodeSnapshot]) -> UInt64 {
    var hash: UInt64 = 14695981039346656037  // FNV offset basis
    for node in nodes {
        for byte in node.role.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211  // FNV prime
        }
        if let title = node.title {
            for byte in title.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
        }
        // Include value prefix (first 50 chars) for change detection
        if let value = node.value?.prefix(50) {
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
        }
    }
    return hash
}

// MARK: - Tree Capture

/// Capture an AX tree snapshot from a running application.
///
/// Walks the focused window's AX tree, serializing each node into an `AXNodeSnapshot`.
/// Computes an FNV-1a hash for deduplication — if the tree hasn't changed since last
/// capture, callers can skip storage.
///
/// Parameters:
/// - app: The application's ShadowElement
/// - appName: Display name of the application
/// - bundleId: Bundle identifier
/// - windowTitle: Title of the focused window (if any)
/// - displayId: Display the window is on (if known)
/// - maxDepth: Maximum semantic depth for tree walk (default 15)
/// - maxNodes: Maximum nodes to capture (default 500)
/// - timeout: Maximum time for tree walk in seconds (default 0.2s for interactive use)
@MainActor
func captureAXTree(
    app: ShadowElement,
    appName: String,
    bundleId: String,
    windowTitle: String?,
    displayId: UInt32?,
    maxDepth: Int = 15,
    maxNodes: Int = 500,
    timeout: TimeInterval = 0.2
) -> AXTreeSnapshotData? {
    var nodes: [AXNodeSnapshot] = []
    var nodeIdCounter: UInt32 = 0

    // Use a stack-based parent tracking approach
    var parentStack: [UInt32] = []

    let root: ShadowElement
    if let window = app.focusedWindow() {
        root = window
    } else {
        root = app
    }

    let startTime = Date()
    var visited = Set<UInt>()

    func walk(_ el: ShadowElement, semanticDepth: Int, realDepth: Int, parentId: UInt32?) {
        guard nodes.count < maxNodes else { return }
        guard Date().timeIntervalSince(startTime) < timeout else { return }
        guard visited.insert(el.cfHash).inserted else { return }
        guard semanticDepth <= maxDepth, realDepth <= maxDepth + 10 else { return }

        let id = nodeIdCounter
        nodeIdCounter += 1

        let role = el.role() ?? "AXUnknown"
        let title = el.title()
        let value = el.value().map { String($0.prefix(200)) }
        let identifier = el.identifier()

        let pos = el.position()
        let sz = el.size()

        nodes.append(AXNodeSnapshot(
            nodeId: id,
            parentId: parentId,
            role: role,
            subrole: el.subrole(),
            title: title,
            value: value,
            identifier: identifier,
            description: el.descriptionText(),
            enabled: el.isEnabled(),
            focused: el.isFocused(),
            posX: pos.map { Float($0.x) },
            posY: pos.map { Float($0.y) },
            width: sz.map { Float($0.width) },
            height: sz.map { Float($0.height) },
            actions: el.supportedActions(),
            domId: el.domId(),
            domClassList: el.domClassList()
        ))

        // Determine if this element can have children
        let isContainer = isContainerRole(role) || realDepth == 0
        guard isContainer else { return }

        let children = el.allChildren(maxCount: 5000)
        let depthCost = isLayoutRole(role) ? 0 : 1

        for child in children {
            guard nodes.count < maxNodes else { return }
            walk(child,
                 semanticDepth: semanticDepth + depthCost,
                 realDepth: realDepth + 1,
                 parentId: id)
        }
    }

    walk(root, semanticDepth: 0, realDepth: 0, parentId: nil)

    guard !nodes.isEmpty else { return nil }

    let treeHash = computeTreeHash(nodes)
    let ts = CaptureSessionClock.wallMicros()

    return AXTreeSnapshotData(
        timestampUs: ts,
        appBundleId: bundleId,
        appName: appName,
        windowTitle: windowTitle,
        displayId: displayId,
        treeHash: treeHash,
        nodeCount: nodes.count,
        nodes: nodes
    )
}

// MARK: - Role Classification Helpers

private let semanticContainerRoles: Set<String> = [
    "AXApplication", "AXWindow", "AXToolbar", "AXMenuBar", "AXMenu",
    "AXMenuItem", "AXSheet", "AXDialog", "AXPopover", "AXDrawer",
    "AXWebArea", "AXTable", "AXOutline", "AXBrowser", "AXTabGroup",
    "AXSplitGroup", "AXScrollArea"
]

private let layoutContainerRoles: Set<String> = [
    "AXGroup", "AXGenericElement", "AXSection", "AXDiv", "AXList",
    "AXLandmarkMain", "AXLandmarkNavigation", "AXLandmarkBanner",
    "AXLandmarkContentInfo", "AXLandmarkSearch", "AXLandmarkComplementary",
    "AXLayoutArea", "AXLayoutItem", "AXSplitter", "AXUnknown"
]

private func isContainerRole(_ role: String) -> Bool {
    semanticContainerRoles.contains(role) || layoutContainerRoles.contains(role)
}

private func isLayoutRole(_ role: String) -> Bool {
    layoutContainerRoles.contains(role)
}
