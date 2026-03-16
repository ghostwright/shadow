import XCTest
@testable import Shadow

final class SafetyGateTests: XCTestCase {

    // MARK: - Hard Rule Checks

    /// Secure text fields are always blocked.
    func testBlocksSecureTextField() async {
        let gate = SafetyGate()
        let violation = await gate.checkHardRules(
            elementRole: "AXSecureTextField",
            bundleId: "com.example.app",
            windowTitle: "Login"
        )
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation!.contains("secure text fields"))
    }

    /// Keychain Access app is always blocked.
    func testBlocksKeychainAccess() async {
        let gate = SafetyGate()
        let violation = await gate.checkHardRules(
            elementRole: "AXButton",
            bundleId: "com.apple.keychainaccess",
            windowTitle: "Keychain Access"
        )
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation!.contains("Keychain"))
    }

    /// System Preferences app is always blocked.
    func testBlocksSystemPreferences() async {
        let gate = SafetyGate()
        let violation = await gate.checkHardRules(
            elementRole: "AXButton",
            bundleId: "com.apple.systempreferences",
            windowTitle: nil
        )
        XCTAssertNotNil(violation)
    }

    /// Security-related window titles are blocked.
    func testBlocksSecurityWindowTitle() async {
        let gate = SafetyGate()
        let securityTitles = [
            "Privacy & Security",
            "Security & Privacy",
            "FileVault Settings",
            "Gatekeeper Configuration"
        ]

        for title in securityTitles {
            let violation = await gate.checkHardRules(
                elementRole: "AXButton",
                bundleId: "com.example.app",
                windowTitle: title
            )
            XCTAssertNotNil(violation, "Should block window: \(title)")
        }
    }

    /// Normal elements in normal apps pass hard rules.
    func testAllowsNormalElements() async {
        let gate = SafetyGate()
        let violation = await gate.checkHardRules(
            elementRole: "AXButton",
            bundleId: "com.apple.Safari",
            windowTitle: "Google"
        )
        XCTAssertNil(violation)
    }

    /// Text fields (non-secure) pass hard rules.
    func testAllowsNonSecureTextField() async {
        let gate = SafetyGate()
        let violation = await gate.checkHardRules(
            elementRole: "AXTextField",
            bundleId: "com.apple.Safari",
            windowTitle: "Search"
        )
        XCTAssertNil(violation)
    }

    // MARK: - Read-Only Classification

    /// Scroll actions are read-only.
    func testScrollIsReadOnly() async {
        let gate = SafetyGate()
        let isReadOnly = await gate.isReadOnlyAction(
            .scroll(deltaX: 0, deltaY: -3, x: 400, y: 300)
        )
        XCTAssertTrue(isReadOnly)
    }

    /// App switch actions are read-only.
    func testAppSwitchIsReadOnly() async {
        let gate = SafetyGate()
        let isReadOnly = await gate.isReadOnlyAction(
            .appSwitch(toApp: "Safari", toBundleId: "com.apple.Safari")
        )
        XCTAssertTrue(isReadOnly)
    }

    /// Click actions are NOT read-only.
    func testClickIsNotReadOnly() async {
        let gate = SafetyGate()
        let isReadOnly = await gate.isReadOnlyAction(
            .click(x: 100, y: 200, button: "left", count: 1)
        )
        XCTAssertFalse(isReadOnly)
    }

    /// Type text actions are NOT read-only.
    func testTypeTextIsNotReadOnly() async {
        let gate = SafetyGate()
        let isReadOnly = await gate.isReadOnlyAction(
            .typeText(text: "hello")
        )
        XCTAssertFalse(isReadOnly)
    }

    /// Key press actions are NOT read-only.
    func testKeyPressIsNotReadOnly() async {
        let gate = SafetyGate()
        let isReadOnly = await gate.isReadOnlyAction(
            .keyPress(keyCode: 36, keyName: "return", modifiers: [])
        )
        XCTAssertFalse(isReadOnly)
    }

    // MARK: - Action Assessment

    /// Read-only action returns low risk.
    func testReadOnlyActionIsLowRisk() async {
        let gate = SafetyGate()
        let assessment = await gate.assessAction(
            actionType: .scroll(deltaX: 0, deltaY: -3, x: 400, y: 300),
            elementRole: nil,
            app: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Google"
        )
        XCTAssertEqual(assessment.riskLevel, .low)
        XCTAssertFalse(assessment.requiresApproval)
    }

    /// Action on secure field is blocked.
    func testSecureFieldActionIsBlocked() async {
        let gate = SafetyGate()
        let assessment = await gate.assessAction(
            actionType: .typeText(text: "password123"),
            elementRole: "AXSecureTextField",
            app: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Login"
        )
        XCTAssertEqual(assessment.riskLevel, .blocked)
        // Blocked level auto-sets requiresApproval via SafetyAssessment.init (blocked >= high)
        XCTAssertTrue(assessment.requiresApproval)
    }

    /// Action without LLM defaults to medium risk.
    func testDefaultMediumRiskWithoutLLM() async {
        let gate = SafetyGate()
        let assessment = await gate.assessAction(
            actionType: .click(x: 100, y: 200, button: "left", count: 1),
            elementRole: "AXButton",
            app: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Google"
        )
        XCTAssertEqual(assessment.riskLevel, .medium)
    }

    // MARK: - Procedure Assessment

    /// Procedure targeting blocked app is blocked entirely.
    func testBlockedAppProcedure() async {
        let gate = SafetyGate()
        let procedure = makeTestProcedure(
            sourceApp: "Keychain Access",
            sourceBundleId: "com.apple.keychainaccess"
        )
        let assessment = await gate.assessProcedure(procedure)
        XCTAssertEqual(assessment.riskLevel, .blocked)
    }

    /// Normal procedure without LLM gets heuristic assessment.
    func testNormalProcedureHeuristic() async {
        let gate = SafetyGate()
        let procedure = makeTestProcedure(
            sourceApp: "Safari",
            sourceBundleId: "com.apple.Safari"
        )
        let assessment = await gate.assessProcedure(procedure)
        XCTAssertNotEqual(assessment.riskLevel, .blocked)
    }

    // MARK: - Safety Risk Level Comparisons

    /// Risk levels are ordered correctly.
    func testRiskLevelOrdering() {
        XCTAssertTrue(SafetyRiskLevel.low < SafetyRiskLevel.medium)
        XCTAssertTrue(SafetyRiskLevel.medium < SafetyRiskLevel.high)
        XCTAssertTrue(SafetyRiskLevel.high < SafetyRiskLevel.critical)
        XCTAssertTrue(SafetyRiskLevel.critical < SafetyRiskLevel.blocked)
    }

    /// Safety assessment auto-requires approval for high risk.
    func testHighRiskRequiresApproval() {
        let assessment = SafetyAssessment(riskLevel: .high, rationale: "Test")
        XCTAssertTrue(assessment.requiresApproval)
    }

    /// Safety assessment auto-requires approval for critical risk.
    func testCriticalRiskRequiresApproval() {
        let assessment = SafetyAssessment(riskLevel: .critical, rationale: "Test")
        XCTAssertTrue(assessment.requiresApproval)
    }

    /// Low risk does not require approval.
    func testLowRiskNoApproval() {
        let assessment = SafetyAssessment(riskLevel: .low, rationale: "Safe action")
        XCTAssertFalse(assessment.requiresApproval)
    }

    // MARK: - Hard Rule Enum

    /// All hard rules have descriptions.
    func testHardRuleDescriptions() {
        for rule in SafetyGate.HardRule.allCases {
            XCTAssertFalse(rule.description.isEmpty, "Hard rule \(rule.rawValue) has no description")
        }
    }

    // MARK: - Helpers

    private func makeTestProcedure(
        sourceApp: String,
        sourceBundleId: String
    ) -> ProcedureTemplate {
        ProcedureTemplate(
            id: "test-proc",
            name: "Test Procedure",
            description: "A test procedure",
            parameters: [],
            steps: [
                ProcedureStep(
                    index: 0,
                    intent: "Click a button",
                    actionType: .click(x: 100, y: 100, button: "left", count: 1),
                    targetLocator: nil,
                    targetDescription: "Test button",
                    parameterSubstitutions: [:],
                    expectedPostCondition: nil,
                    maxRetries: 2,
                    timeoutSeconds: 5.0
                ),
                ProcedureStep(
                    index: 1,
                    intent: "Type some text",
                    actionType: .typeText(text: "hello"),
                    targetLocator: nil,
                    targetDescription: "Text field",
                    parameterSubstitutions: [:],
                    expectedPostCondition: nil,
                    maxRetries: 2,
                    timeoutSeconds: 5.0
                )
            ],
            createdAt: CaptureSessionClock.wallMicros(),
            updatedAt: CaptureSessionClock.wallMicros(),
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId,
            tags: ["test"],
            executionCount: 0,
            lastExecutedAt: nil
        )
    }
}
