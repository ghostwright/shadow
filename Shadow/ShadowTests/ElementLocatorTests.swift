import XCTest
@testable import Shadow

final class ElementLocatorTests: XCTestCase {

    // MARK: - ElementLocator Codable

    /// Full round-trip of ElementLocator with all fields populated.
    func testLocatorCodableRoundTrip() throws {
        let locator = ElementLocator(
            role: "AXButton",
            title: "Submit",
            identifier: "btn_submit",
            domId: "submit-btn",
            domClass: "primary-button",
            value: nil,
            pathHints: [
                ElementLocator.PathHint(
                    role: "AXGroup",
                    childIndex: 2,
                    title: "Form Actions",
                    identifier: "form-actions"
                ),
                ElementLocator.PathHint(
                    role: "AXWindow",
                    childIndex: 0,
                    title: "New Document",
                    identifier: nil
                ),
            ],
            positionFallback: CGPoint(x: 400, y: 300)
        )

        let data = try JSONEncoder().encode(locator)
        let decoded = try JSONDecoder().decode(ElementLocator.self, from: data)

        XCTAssertEqual(decoded.role, "AXButton")
        XCTAssertEqual(decoded.title, "Submit")
        XCTAssertEqual(decoded.identifier, "btn_submit")
        XCTAssertEqual(decoded.domId, "submit-btn")
        XCTAssertEqual(decoded.domClass, "primary-button")
        XCTAssertNil(decoded.value)
        XCTAssertEqual(decoded.pathHints.count, 2)
        XCTAssertEqual(decoded.pathHints[0].role, "AXGroup")
        XCTAssertEqual(decoded.pathHints[0].childIndex, 2)
        XCTAssertEqual(decoded.pathHints[0].title, "Form Actions")
        XCTAssertEqual(decoded.pathHints[1].role, "AXWindow")
        XCTAssertEqual(decoded.pathHints[1].childIndex, 0)
        XCTAssertEqual(decoded.positionFallback?.x, 400)
        XCTAssertEqual(decoded.positionFallback?.y, 300)
    }

    /// Locator with nil optional fields encodes and decodes.
    func testLocatorMinimalFields() throws {
        let locator = ElementLocator(
            role: "AXStaticText",
            title: nil,
            identifier: nil,
            domId: nil,
            domClass: nil,
            value: "Some text content",
            pathHints: [],
            positionFallback: nil
        )

        let data = try JSONEncoder().encode(locator)
        let decoded = try JSONDecoder().decode(ElementLocator.self, from: data)

        XCTAssertEqual(decoded.role, "AXStaticText")
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.identifier)
        XCTAssertNil(decoded.domId)
        XCTAssertNil(decoded.domClass)
        XCTAssertEqual(decoded.value, "Some text content")
        XCTAssertTrue(decoded.pathHints.isEmpty)
        XCTAssertNil(decoded.positionFallback)
    }

    // MARK: - PathHint Codable

    /// PathHint round-trip with all fields.
    func testPathHintCodable() throws {
        let hint = ElementLocator.PathHint(
            role: "AXToolbar",
            childIndex: 5,
            title: "Navigation Bar",
            identifier: "nav_toolbar"
        )

        let data = try JSONEncoder().encode(hint)
        let decoded = try JSONDecoder().decode(ElementLocator.PathHint.self, from: data)

        XCTAssertEqual(decoded.role, "AXToolbar")
        XCTAssertEqual(decoded.childIndex, 5)
        XCTAssertEqual(decoded.title, "Navigation Bar")
        XCTAssertEqual(decoded.identifier, "nav_toolbar")
    }

    /// PathHint with nil title/identifier.
    func testPathHintNilOptionals() throws {
        let hint = ElementLocator.PathHint(
            role: "AXGroup",
            childIndex: 0,
            title: nil,
            identifier: nil
        )

        let data = try JSONEncoder().encode(hint)
        let decoded = try JSONDecoder().decode(ElementLocator.PathHint.self, from: data)

        XCTAssertEqual(decoded.role, "AXGroup")
        XCTAssertEqual(decoded.childIndex, 0)
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.identifier)
    }

    // MARK: - CGPoint Codable

    /// CGPoint round-trip via the retroactive Codable conformance.
    func testCGPointCodable() throws {
        let point = CGPoint(x: 123.456, y: 789.012)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(CGPoint.self, from: data)

        XCTAssertEqual(decoded.x, 123.456, accuracy: 0.001)
        XCTAssertEqual(decoded.y, 789.012, accuracy: 0.001)
    }

    /// CGPoint zero encodes and decodes.
    func testCGPointZero() throws {
        let point = CGPoint.zero
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(CGPoint.self, from: data)

        XCTAssertEqual(decoded.x, 0)
        XCTAssertEqual(decoded.y, 0)
    }

    /// CGPoint with negative coordinates.
    func testCGPointNegative() throws {
        let point = CGPoint(x: -100.5, y: -200.75)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(CGPoint.self, from: data)

        XCTAssertEqual(decoded.x, -100.5, accuracy: 0.001)
        XCTAssertEqual(decoded.y, -200.75, accuracy: 0.001)
    }

    // MARK: - Locator JSON Interop

    /// Verify that serialized locator produces valid JSON (not an implementation detail,
    /// but important for persistence to ~/.shadow/data/procedures/).
    func testLocatorProducesValidJSON() throws {
        let locator = ElementLocator(
            role: "AXButton",
            title: "OK",
            identifier: nil,
            domId: nil,
            domClass: nil,
            value: nil,
            pathHints: [
                ElementLocator.PathHint(role: "AXDialog", childIndex: 1, title: "Confirm", identifier: nil)
            ],
            positionFallback: CGPoint(x: 50, y: 50)
        )

        let data = try JSONEncoder().encode(locator)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["role"] as? String, "AXButton")
        XCTAssertEqual(json?["title"] as? String, "OK")

        let hints = json?["pathHints"] as? [[String: Any]]
        XCTAssertEqual(hints?.count, 1)
        XCTAssertEqual(hints?[0]["role"] as? String, "AXDialog")
        XCTAssertEqual(hints?[0]["childIndex"] as? Int, 1)
    }

    // MARK: - Multiple Locators (array serialization for procedure steps)

    /// An array of locators serializes correctly.
    func testLocatorArrayCodable() throws {
        let locators = [
            ElementLocator(
                role: "AXTextField", title: nil, identifier: "email_field",
                domId: nil, domClass: nil, value: nil, pathHints: [],
                positionFallback: nil
            ),
            ElementLocator(
                role: "AXButton", title: "Sign In", identifier: nil,
                domId: "signin-btn", domClass: "btn-primary", value: nil,
                pathHints: [], positionFallback: CGPoint(x: 200, y: 400)
            ),
        ]

        let data = try JSONEncoder().encode(locators)
        let decoded = try JSONDecoder().decode([ElementLocator].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].role, "AXTextField")
        XCTAssertEqual(decoded[0].identifier, "email_field")
        XCTAssertEqual(decoded[1].role, "AXButton")
        XCTAssertEqual(decoded[1].domId, "signin-btn")
    }
}
