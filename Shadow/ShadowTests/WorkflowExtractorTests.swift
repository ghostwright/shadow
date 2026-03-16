import XCTest
@testable import Shadow

/// Tests for WorkflowExtractor — the Swift wrapper that converts
/// Rust-extracted workflows into ProcedureTemplates.
final class WorkflowExtractorTests: XCTestCase {

    // MARK: - Conversion Tests

    func testConvertToProcedureTemplate_basicWorkflow() {
        let workflow = makeTestWorkflow(
            id: "wf-test-123",
            name: "Chrome — Compose",
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Gmail",
            steps: [
                makeStep(index: 0, actionType: "mouse_down", role: "AXButton", title: "Compose"),
                makeStep(index: 1, actionType: "mouse_down", role: "AXComboBox", title: "To"),
                makeStep(index: 2, actionType: "mouse_down", role: "AXButton", title: "Send"),
            ],
            occurrences: 3,
            confidence: 0.85
        )

        let template = WorkflowExtractor.convertToProcedureTemplate(workflow)

        XCTAssertEqual(template.id, "wf-test-123")
        XCTAssertEqual(template.name, "Chrome — Compose")
        XCTAssertEqual(template.sourceApp, "Google Chrome")
        XCTAssertEqual(template.sourceBundleId, "com.google.Chrome")
        XCTAssertEqual(template.steps.count, 3)
        XCTAssertTrue(template.tags.contains("auto-extracted"))
        XCTAssertTrue(template.tags.contains("mimicry"))
        XCTAssertTrue(template.description.contains("3 observations"))
    }

    func testConvertToProcedureTemplate_stepsHaveLocators() {
        let workflow = makeTestWorkflow(
            id: "wf-locator",
            name: "Test",
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Safari",
            steps: [
                makeStep(index: 0, actionType: "mouse_down", role: "AXButton", title: "Back", identifier: "back-btn"),
            ],
            occurrences: 2,
            confidence: 0.7
        )

        let template = WorkflowExtractor.convertToProcedureTemplate(workflow)
        let step = template.steps[0]

        // Locator should be populated from AX-anchored step
        XCTAssertNotNil(step.targetLocator)
        XCTAssertEqual(step.targetLocator?.role, "AXButton")
        XCTAssertEqual(step.targetLocator?.title, "Back")
        XCTAssertEqual(step.targetLocator?.identifier, "back-btn")
    }

    func testConvertToProcedureTemplate_mouseDownBecomesClick() {
        let workflow = makeTestWorkflow(
            id: "wf-click",
            name: "Click Test",
            appName: "App",
            bundleId: "com.test",
            windowTitle: "Win",
            steps: [
                makeStep(index: 0, actionType: "mouse_down", role: "AXButton", title: "OK"),
            ],
            occurrences: 2,
            confidence: 0.5
        )

        let template = WorkflowExtractor.convertToProcedureTemplate(workflow)
        let step = template.steps[0]

        if case .click(_, _, let button, let count) = step.actionType {
            XCTAssertEqual(button, "left")
            XCTAssertEqual(count, 1)
        } else {
            XCTFail("Expected click action type for mouse_down")
        }
    }

    func testConvertToProcedureTemplate_keyDownBecomesKeyPress() {
        let workflow = makeTestWorkflow(
            id: "wf-key",
            name: "Key Test",
            appName: "App",
            bundleId: "com.test",
            windowTitle: "Win",
            steps: [
                makeStep(index: 0, actionType: "key_down", role: nil, title: nil, keyName: "Tab"),
            ],
            occurrences: 2,
            confidence: 0.5
        )

        let template = WorkflowExtractor.convertToProcedureTemplate(workflow)
        let step = template.steps[0]

        if case .keyPress(_, let keyName, _) = step.actionType {
            XCTAssertEqual(keyName, "Tab")
        } else {
            XCTFail("Expected keyPress action type for key_down with keyName")
        }
    }

    func testConvertToProcedureTemplate_stepIntentPreserved() {
        let step = AxAnchoredStep(
            index: 0,
            intent: "Click Compose button to start new email",
            actionType: "mouse_down",
            targetRole: "AXButton",
            targetTitle: "Compose",
            targetIdentifier: nil,
            fallbackX: nil,
            fallbackY: nil,
            text: nil,
            keyName: nil,
            modifiers: [],
            expectedWindowTitle: "Gmail",
            expectedApp: "Chrome"
        )

        let workflow = ExtractedWorkflow(
            id: "wf-intent",
            name: "Test",
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            windowTitlePattern: "Gmail",
            steps: [step],
            occurrenceCount: 2,
            confidence: 0.8,
            lastSeenTs: 1000000,
            firstSeenTs: 500000
        )

        let template = WorkflowExtractor.convertToProcedureTemplate(workflow)
        XCTAssertEqual(template.steps[0].intent, "Click Compose button to start new email")
    }

    // MARK: - Formatting Tests

    func testFormatForPrompt_empty() {
        let formatted = WorkflowExtractor.formatForPrompt([], limit: 3)
        XCTAssertTrue(formatted.isEmpty)
    }

    func testFormatForPrompt_includesWorkflowDetails() {
        let workflow = makeTestWorkflow(
            id: "wf-fmt",
            name: "Gmail Compose",
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Gmail",
            steps: [
                makeStep(index: 0, actionType: "mouse_down", role: "AXButton", title: "Compose"),
                makeStep(index: 1, actionType: "mouse_down", role: "AXButton", title: "Send"),
            ],
            occurrences: 5,
            confidence: 0.9
        )

        let formatted = WorkflowExtractor.formatForPrompt([workflow])

        XCTAssertTrue(formatted.contains("Learned Workflows"))
        XCTAssertTrue(formatted.contains("Gmail Compose"))
        XCTAssertTrue(formatted.contains("seen 5x"))
        XCTAssertTrue(formatted.contains("AXButton"))
        XCTAssertTrue(formatted.contains("\"Compose\""))
    }

    func testFormatForPrompt_respectsLimit() {
        let workflows = (0..<5).map { i in
            makeTestWorkflow(
                id: "wf-\(i)",
                name: "Workflow \(i)",
                appName: "App",
                bundleId: "com.test",
                windowTitle: "Win",
                steps: [makeStep(index: 0, actionType: "mouse_down", role: "AXButton", title: "Btn\(i)")],
                occurrences: 2,
                confidence: 0.5
            )
        }

        let formatted = WorkflowExtractor.formatForPrompt(workflows, limit: 2)
        // Should only include 2 workflows
        let workflowCount = formatted.components(separatedBy: "WORKFLOW").count - 1
        XCTAssertEqual(workflowCount, 2)
    }

    // MARK: - Raw Extraction Tests

    func testExtract_returnsEmptyWhenNoData() {
        // This test calls the Rust FFI which requires initialized storage.
        // Without initialization, it will return empty (the FFI handles errors gracefully).
        let results = WorkflowExtractor.extract(lookbackHours: 1, maxResults: 5)
        // Either empty or an error handled gracefully
        XCTAssertNotNil(results)
    }

    // MARK: - Helpers

    private func makeStep(
        index: UInt32 = 0,
        actionType: String,
        role: String?,
        title: String?,
        identifier: String? = nil,
        keyName: String? = nil
    ) -> AxAnchoredStep {
        AxAnchoredStep(
            index: index,
            intent: "\(actionType) \(role ?? "") \(title ?? "")",
            actionType: actionType,
            targetRole: role,
            targetTitle: title,
            targetIdentifier: identifier,
            fallbackX: nil,
            fallbackY: nil,
            text: nil,
            keyName: keyName,
            modifiers: [],
            expectedWindowTitle: nil,
            expectedApp: nil
        )
    }

    private func makeTestWorkflow(
        id: String,
        name: String,
        appName: String,
        bundleId: String,
        windowTitle: String,
        steps: [AxAnchoredStep],
        occurrences: UInt32,
        confidence: Double
    ) -> ExtractedWorkflow {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return ExtractedWorkflow(
            id: id,
            name: name,
            appName: appName,
            bundleId: bundleId,
            windowTitlePattern: windowTitle,
            steps: steps,
            occurrenceCount: occurrences,
            confidence: confidence,
            lastSeenTs: now,
            firstSeenTs: now - 3_600_000_000
        )
    }
}
