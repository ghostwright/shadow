import XCTest
@testable import Shadow

final class ProcedureTypesTests: XCTestCase {

    // MARK: - RecordedAction.ActionType Codable

    /// Click action round-trips through JSON.
    func testClickActionCodable() throws {
        let action = RecordedAction.ActionType.click(x: 100.5, y: 200.0, button: "left", count: 2)
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(RecordedAction.ActionType.self, from: data)

        if case .click(let x, let y, let button, let count) = decoded {
            XCTAssertEqual(x, 100.5, accuracy: 0.01)
            XCTAssertEqual(y, 200.0, accuracy: 0.01)
            XCTAssertEqual(button, "left")
            XCTAssertEqual(count, 2)
        } else {
            XCTFail("Expected click action type")
        }
    }

    /// TypeText action round-trips.
    func testTypeTextActionCodable() throws {
        let action = RecordedAction.ActionType.typeText(text: "Hello, world!")
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(RecordedAction.ActionType.self, from: data)

        if case .typeText(let text) = decoded {
            XCTAssertEqual(text, "Hello, world!")
        } else {
            XCTFail("Expected typeText action type")
        }
    }

    /// KeyPress action round-trips.
    func testKeyPressActionCodable() throws {
        let action = RecordedAction.ActionType.keyPress(keyCode: 36, keyName: "return", modifiers: ["cmd", "shift"])
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(RecordedAction.ActionType.self, from: data)

        if case .keyPress(let keyCode, let keyName, let modifiers) = decoded {
            XCTAssertEqual(keyCode, 36)
            XCTAssertEqual(keyName, "return")
            XCTAssertEqual(modifiers, ["cmd", "shift"])
        } else {
            XCTFail("Expected keyPress action type")
        }
    }

    /// AppSwitch action round-trips.
    func testAppSwitchActionCodable() throws {
        let action = RecordedAction.ActionType.appSwitch(toApp: "Safari", toBundleId: "com.apple.Safari")
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(RecordedAction.ActionType.self, from: data)

        if case .appSwitch(let toApp, let toBundleId) = decoded {
            XCTAssertEqual(toApp, "Safari")
            XCTAssertEqual(toBundleId, "com.apple.Safari")
        } else {
            XCTFail("Expected appSwitch action type")
        }
    }

    /// Scroll action round-trips.
    func testScrollActionCodable() throws {
        let action = RecordedAction.ActionType.scroll(deltaX: 0, deltaY: -3, x: 400, y: 300)
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(RecordedAction.ActionType.self, from: data)

        if case .scroll(let dx, let dy, let x, let y) = decoded {
            XCTAssertEqual(dx, 0)
            XCTAssertEqual(dy, -3)
            XCTAssertEqual(x, 400, accuracy: 0.01)
            XCTAssertEqual(y, 300, accuracy: 0.01)
        } else {
            XCTFail("Expected scroll action type")
        }
    }

    // MARK: - RecordedAction Codable

    /// Full RecordedAction round-trips.
    func testRecordedActionCodable() throws {
        let action = RecordedAction(
            timestamp: 1700000000_000000,
            actionType: .click(x: 50, y: 100, button: "left", count: 1),
            appName: "Safari",
            appBundleId: "com.apple.Safari",
            windowTitle: "Google",
            targetLocator: nil,
            targetDescription: "Search field",
            preTreeHash: 12345,
            postTreeHash: 67890,
            nodeCountBefore: 150,
            nodeCountAfter: 155
        )

        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(RecordedAction.self, from: data)

        XCTAssertEqual(decoded.timestamp, 1700000000_000000)
        XCTAssertEqual(decoded.appName, "Safari")
        XCTAssertEqual(decoded.appBundleId, "com.apple.Safari")
        XCTAssertEqual(decoded.windowTitle, "Google")
        XCTAssertNil(decoded.targetLocator)
        XCTAssertEqual(decoded.targetDescription, "Search field")
        XCTAssertEqual(decoded.preTreeHash, 12345)
        XCTAssertEqual(decoded.postTreeHash, 67890)
    }

    // MARK: - ProcedureTemplate Codable

    /// Full ProcedureTemplate round-trips.
    func testProcedureTemplateCodable() throws {
        let template = ProcedureTemplate(
            id: "test-uuid",
            name: "Send Email",
            description: "Send an email to a recipient",
            parameters: [
                ProcedureParameter(
                    name: "recipient",
                    paramType: "email",
                    description: "Email address of the recipient",
                    stepIndices: [1],
                    defaultValue: "test@example.com"
                )
            ],
            steps: [
                ProcedureStep(
                    index: 0,
                    intent: "Open compose window",
                    actionType: .click(x: 100, y: 50, button: "left", count: 1),
                    targetLocator: nil,
                    targetDescription: "Compose button",
                    parameterSubstitutions: [:],
                    expectedPostCondition: "Compose window opens",
                    maxRetries: 2,
                    timeoutSeconds: 5.0
                ),
                ProcedureStep(
                    index: 1,
                    intent: "Enter recipient email",
                    actionType: .typeText(text: "test@example.com"),
                    targetLocator: nil,
                    targetDescription: "To field",
                    parameterSubstitutions: ["recipient": "test@example.com"],
                    expectedPostCondition: nil,
                    maxRetries: 2,
                    timeoutSeconds: 5.0
                )
            ],
            createdAt: 1700000000_000000,
            updatedAt: 1700000000_000000,
            sourceApp: "Mail",
            sourceBundleId: "com.apple.mail",
            tags: ["email", "compose"],
            executionCount: 0,
            lastExecutedAt: nil
        )

        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(ProcedureTemplate.self, from: data)

        XCTAssertEqual(decoded.id, "test-uuid")
        XCTAssertEqual(decoded.name, "Send Email")
        XCTAssertEqual(decoded.description, "Send an email to a recipient")
        XCTAssertEqual(decoded.parameters.count, 1)
        XCTAssertEqual(decoded.parameters[0].name, "recipient")
        XCTAssertEqual(decoded.parameters[0].paramType, "email")
        XCTAssertEqual(decoded.steps.count, 2)
        XCTAssertEqual(decoded.steps[0].intent, "Open compose window")
        XCTAssertEqual(decoded.steps[1].parameterSubstitutions["recipient"], "test@example.com")
        XCTAssertEqual(decoded.tags, ["email", "compose"])
        XCTAssertEqual(decoded.sourceApp, "Mail")
        XCTAssertEqual(decoded.executionCount, 0)
        XCTAssertNil(decoded.lastExecutedAt)
    }

    // MARK: - ProcedureParameter

    /// Parameter with nil defaultValue.
    func testParameterNoDefault() throws {
        let param = ProcedureParameter(
            name: "search_query",
            paramType: "string",
            description: "What to search for",
            stepIndices: [0, 2],
            defaultValue: nil
        )

        let data = try JSONEncoder().encode(param)
        let decoded = try JSONDecoder().decode(ProcedureParameter.self, from: data)

        XCTAssertEqual(decoded.name, "search_query")
        XCTAssertNil(decoded.defaultValue)
        XCTAssertEqual(decoded.stepIndices, [0, 2])
    }

    // MARK: - ProcedureExecutionStatus

    /// All status values encode to expected strings.
    func testExecutionStatusValues() throws {
        let statuses: [ProcedureExecutionStatus] = [.running, .paused, .completed, .failed, .cancelled]
        let expectedRawValues = ["running", "paused", "completed", "failed", "cancelled"]

        for (status, expected) in zip(statuses, expectedRawValues) {
            XCTAssertEqual(status.rawValue, expected)
        }
    }

    /// ExecutionStatus round-trips through Codable.
    func testExecutionStatusCodable() throws {
        for status in [ProcedureExecutionStatus.running, .paused, .completed, .failed, .cancelled] {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(ProcedureExecutionStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }
}
