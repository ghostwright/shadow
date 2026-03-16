import XCTest
@testable import Shadow

final class AXTreeCaptureTests: XCTestCase {

    // MARK: - FNV-1a Hash

    /// Empty node list produces the FNV offset basis (no data mixed in).
    func testTreeHashEmptyNodes() {
        let hash = computeTreeHash([])
        let fnvOffsetBasis: UInt64 = 14695981039346656037
        XCTAssertEqual(hash, fnvOffsetBasis)
    }

    /// A single node produces a deterministic hash.
    func testTreeHashSingleNode() {
        let node = makeNode(role: "AXButton", title: "OK")
        let hash = computeTreeHash([node])
        XCTAssertNotEqual(hash, 14695981039346656037, "Should differ from offset basis")

        // Same node again should produce the identical hash
        let hash2 = computeTreeHash([node])
        XCTAssertEqual(hash, hash2, "Hash must be deterministic")
    }

    /// Different nodes produce different hashes.
    func testTreeHashDifferentNodes() {
        let nodeA = makeNode(role: "AXButton", title: "OK")
        let nodeB = makeNode(role: "AXButton", title: "Cancel")

        let hashA = computeTreeHash([nodeA])
        let hashB = computeTreeHash([nodeB])
        XCTAssertNotEqual(hashA, hashB, "Different titles should produce different hashes")
    }

    /// Value prefix (first 50 chars) affects the hash.
    func testTreeHashValuePrefix() {
        let nodeA = makeNode(role: "AXTextField", title: nil, value: "hello world")
        let nodeB = makeNode(role: "AXTextField", title: nil, value: "goodbye world")

        let hashA = computeTreeHash([nodeA])
        let hashB = computeTreeHash([nodeB])
        XCTAssertNotEqual(hashA, hashB, "Different values should produce different hashes")
    }

    /// Value beyond 50 chars doesn't affect the hash (prefix truncation).
    func testTreeHashValuePrefixTruncation() {
        let prefix = String(repeating: "a", count: 50)
        let valueA = prefix + "XXXXX"
        let valueB = prefix + "YYYYY"

        let nodeA = makeNode(role: "AXTextField", title: nil, value: valueA)
        let nodeB = makeNode(role: "AXTextField", title: nil, value: valueB)

        let hashA = computeTreeHash([nodeA])
        let hashB = computeTreeHash([nodeB])
        XCTAssertEqual(hashA, hashB, "Characters beyond 50 should not affect hash")
    }

    /// Node order matters for the hash (different order = different hash).
    func testTreeHashOrderMatters() {
        let nodeA = makeNode(role: "AXButton", title: "OK")
        let nodeB = makeNode(role: "AXButton", title: "Cancel")

        let hash1 = computeTreeHash([nodeA, nodeB])
        let hash2 = computeTreeHash([nodeB, nodeA])
        XCTAssertNotEqual(hash1, hash2, "Different node order should produce different hashes")
    }

    /// Role-only nodes produce distinct hashes for different roles.
    func testTreeHashRoleOnly() {
        let nodeA = makeNode(role: "AXButton")
        let nodeB = makeNode(role: "AXTextField")

        let hashA = computeTreeHash([nodeA])
        let hashB = computeTreeHash([nodeB])
        XCTAssertNotEqual(hashA, hashB)
    }

    /// Large node list completes quickly (performance baseline).
    func testTreeHashPerformance() {
        let nodes = (0..<500).map { i in
            makeNode(role: "AXStaticText", title: "Label \(i)")
        }

        measure {
            _ = computeTreeHash(nodes)
        }
    }

    // MARK: - AXNodeSnapshot Codable

    /// Round-trip encoding/decoding preserves all fields.
    func testNodeSnapshotCodable() throws {
        let node = AXNodeSnapshot(
            nodeId: 42,
            parentId: 1,
            role: "AXButton",
            subrole: "AXCloseButton",
            title: "Close",
            value: nil,
            identifier: "btn_close",
            description: "Close this window",
            enabled: true,
            focused: false,
            posX: 100.5,
            posY: 200.0,
            width: 44.0,
            height: 44.0,
            actions: ["AXPress", "AXShowMenu"],
            domId: nil,
            domClassList: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(node)
        let decoded = try JSONDecoder().decode(AXNodeSnapshot.self, from: data)

        XCTAssertEqual(decoded.nodeId, 42)
        XCTAssertEqual(decoded.parentId, 1)
        XCTAssertEqual(decoded.role, "AXButton")
        XCTAssertEqual(decoded.subrole, "AXCloseButton")
        XCTAssertEqual(decoded.title, "Close")
        XCTAssertNil(decoded.value)
        XCTAssertEqual(decoded.identifier, "btn_close")
        XCTAssertEqual(decoded.description, "Close this window")
        XCTAssertTrue(decoded.enabled)
        XCTAssertFalse(decoded.focused)
        XCTAssertEqual(decoded.posX, 100.5)
        XCTAssertEqual(decoded.posY, 200.0)
        XCTAssertEqual(decoded.width, 44.0)
        XCTAssertEqual(decoded.height, 44.0)
        XCTAssertEqual(decoded.actions, ["AXPress", "AXShowMenu"])
        XCTAssertNil(decoded.domId)
        XCTAssertNil(decoded.domClassList)
    }

    /// AXTreeSnapshotData round-trip preserves structure.
    func testTreeSnapshotDataCodable() throws {
        let node = makeNode(role: "AXWindow", title: "Main Window")
        let snapshot = AXTreeSnapshotData(
            timestampUs: 1700000000_000000,
            appBundleId: "com.example.app",
            appName: "ExampleApp",
            windowTitle: "Main Window",
            displayId: 1,
            treeHash: 12345678901234,
            nodeCount: 1,
            nodes: [node]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AXTreeSnapshotData.self, from: data)

        XCTAssertEqual(decoded.timestampUs, 1700000000_000000)
        XCTAssertEqual(decoded.appBundleId, "com.example.app")
        XCTAssertEqual(decoded.appName, "ExampleApp")
        XCTAssertEqual(decoded.windowTitle, "Main Window")
        XCTAssertEqual(decoded.displayId, 1)
        XCTAssertEqual(decoded.treeHash, 12345678901234)
        XCTAssertEqual(decoded.nodeCount, 1)
        XCTAssertEqual(decoded.nodes.count, 1)
        XCTAssertEqual(decoded.nodes[0].role, "AXWindow")
    }

    /// Node with nil optional fields encodes and decodes correctly.
    func testNodeSnapshotNilFields() throws {
        let node = AXNodeSnapshot(
            nodeId: 0,
            parentId: nil,
            role: "AXUnknown",
            subrole: nil,
            title: nil,
            value: nil,
            identifier: nil,
            description: nil,
            enabled: true,
            focused: false,
            posX: nil,
            posY: nil,
            width: nil,
            height: nil,
            actions: [],
            domId: nil,
            domClassList: nil
        )

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(AXNodeSnapshot.self, from: data)

        XCTAssertEqual(decoded.nodeId, 0)
        XCTAssertNil(decoded.parentId)
        XCTAssertEqual(decoded.role, "AXUnknown")
        XCTAssertNil(decoded.subrole)
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.value)
        XCTAssertNil(decoded.identifier)
        XCTAssertTrue(decoded.actions.isEmpty)
    }

    // MARK: - Helpers

    private func makeNode(
        role: String,
        title: String? = nil,
        value: String? = nil,
        identifier: String? = nil
    ) -> AXNodeSnapshot {
        AXNodeSnapshot(
            nodeId: 0,
            parentId: nil,
            role: role,
            subrole: nil,
            title: title,
            value: value,
            identifier: identifier,
            description: nil,
            enabled: true,
            focused: false,
            posX: nil,
            posY: nil,
            width: nil,
            height: nil,
            actions: [],
            domId: nil,
            domClassList: nil
        )
    }
}
