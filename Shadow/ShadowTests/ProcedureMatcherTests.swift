import XCTest
@testable import Shadow

final class ProcedureMatcherTests: XCTestCase {

    // MARK: - ProcedureMatch Type

    /// ProcedureMatch is Equatable.
    func testMatchEquatable() {
        let m1 = ProcedureMatcher.ProcedureMatch(
            procedureId: "p1", procedureName: "Test", score: 0.8,
            matchReason: "Same app", sourceApp: "Safari"
        )
        let m2 = ProcedureMatcher.ProcedureMatch(
            procedureId: "p1", procedureName: "Test", score: 0.8,
            matchReason: "Same app", sourceApp: "Safari"
        )
        XCTAssertEqual(m1, m2)
    }

    // MARK: - Heuristic Matching

    /// Exact bundle ID match scores 0.9.
    func testHeuristicBundleIdMatch() {
        let context = makeContext(app: "Safari", bundleId: "com.apple.Safari")
        let procedures = [makeProcedure(sourceApp: "Safari", sourceBundleId: "com.apple.Safari")]

        let matches = ProcedureMatcher.heuristicMatch(context: context, procedures: procedures)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].score, 0.9)
        XCTAssertTrue(matches[0].matchReason.contains("bundle ID"))
    }

    /// App name match scores 0.8.
    func testHeuristicAppNameMatch() {
        let context = makeContext(app: "VS Code", bundleId: "com.microsoft.VSCode")
        let procedures = [makeProcedure(sourceApp: "VS Code", sourceBundleId: "com.unknown.vscode")]

        let matches = ProcedureMatcher.heuristicMatch(context: context, procedures: procedures)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].score, 0.8)
    }

    /// Recent app match scores 0.6.
    func testHeuristicRecentAppMatch() {
        let context = makeContext(app: "Finder", recentApps: ["VS Code", "Safari", "Slack"])
        let procedures = [makeProcedure(sourceApp: "Slack", sourceBundleId: "com.slack")]

        let matches = ProcedureMatcher.heuristicMatch(context: context, procedures: procedures)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].score, 0.6)
    }

    /// Tag match against window title scores 0.4.
    func testHeuristicTagMatch() {
        let context = makeContext(app: "Chrome", windowTitle: "Pull Request Review")
        let procedures = [makeProcedure(
            sourceApp: "GitHub", sourceBundleId: "com.github",
            tags: ["pull", "review"]
        )]

        let matches = ProcedureMatcher.heuristicMatch(context: context, procedures: procedures)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].score, 0.4)
    }

    /// No match returns empty array.
    func testHeuristicNoMatch() {
        let context = makeContext(app: "Calculator")
        let procedures = [makeProcedure(sourceApp: "Figma", sourceBundleId: "com.figma")]

        let matches = ProcedureMatcher.heuristicMatch(context: context, procedures: procedures)
        XCTAssertTrue(matches.isEmpty)
    }

    /// Bundle ID match takes precedence over app name match.
    func testHeuristicHighestScoreWins() {
        let context = makeContext(
            app: "Safari",
            bundleId: "com.apple.Safari",
            recentApps: ["Safari"]
        )
        let procedures = [makeProcedure(sourceApp: "Safari", sourceBundleId: "com.apple.Safari")]

        let matches = ProcedureMatcher.heuristicMatch(context: context, procedures: procedures)
        XCTAssertEqual(matches.count, 1)
        // Should get the highest score (0.9 for bundle ID, not 0.8 for name or 0.6 for recent)
        XCTAssertEqual(matches[0].score, 0.9)
    }

    /// Multiple procedures can match.
    func testHeuristicMultipleMatches() {
        let context = makeContext(app: "Safari", bundleId: "com.apple.Safari")
        let procedures = [
            makeProcedure(id: "p1", sourceApp: "Safari", sourceBundleId: "com.apple.Safari"),
            makeProcedure(id: "p2", sourceApp: "Safari", sourceBundleId: "com.apple.Safari"),
            makeProcedure(id: "p3", sourceApp: "Figma", sourceBundleId: "com.figma"),
        ]

        let matches = ProcedureMatcher.heuristicMatch(context: context, procedures: procedures)
        XCTAssertEqual(matches.count, 2)
    }

    /// Case insensitive app name matching.
    func testHeuristicCaseInsensitive() {
        let context = makeContext(app: "SAFARI", bundleId: nil)
        let procedures = [makeProcedure(sourceApp: "safari", sourceBundleId: "other")]

        let matches = ProcedureMatcher.heuristicMatch(context: context, procedures: procedures)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].score, 0.8)
    }

    // MARK: - Full Match (Async)

    /// Match with no procedures returns empty.
    func testMatchEmptyProcedures() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-matcher-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ProcedureStore(directory: tempDir)
        let context = makeContext(app: "Safari")

        let matches = await ProcedureMatcher.match(context: context, store: store)
        XCTAssertTrue(matches.isEmpty)
    }

    /// Match returns results sorted by score descending.
    func testMatchSortedByScore() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-matcher-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ProcedureStore(directory: tempDir)
        try? await store.save(makeProcedure(
            id: "low", name: "Low match",
            sourceApp: "OtherApp", sourceBundleId: "com.other",
            tags: ["safari"]
        ))
        try? await store.save(makeProcedure(
            id: "high", name: "High match",
            sourceApp: "Safari", sourceBundleId: "com.apple.Safari"
        ))

        let context = makeContext(
            app: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "safari page"
        )

        let matches = await ProcedureMatcher.match(context: context, store: store)
        XCTAssertGreaterThanOrEqual(matches.count, 1)
        if matches.count >= 2 {
            XCTAssertGreaterThanOrEqual(matches[0].score, matches[1].score)
        }
    }

    /// maxResults limits output.
    func testMatchMaxResults() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-matcher-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ProcedureStore(directory: tempDir)
        for i in 0..<5 {
            try? await store.save(makeProcedure(
                id: "p-\(i)", name: "Proc \(i)",
                sourceApp: "Safari", sourceBundleId: "com.apple.Safari"
            ))
        }

        let context = makeContext(app: "Safari", bundleId: "com.apple.Safari")
        let matches = await ProcedureMatcher.match(context: context, store: store, maxResults: 2)
        XCTAssertLessThanOrEqual(matches.count, 2)
    }

    // MARK: - ActivityContext

    /// ActivityContext captures all fields.
    func testActivityContext() {
        let ctx = ProcedureMatcher.ActivityContext(
            currentApp: "Safari",
            currentBundleId: "com.apple.Safari",
            windowTitle: "Google",
            url: "https://google.com",
            recentApps: ["VS Code", "Safari"]
        )
        XCTAssertEqual(ctx.currentApp, "Safari")
        XCTAssertEqual(ctx.currentBundleId, "com.apple.Safari")
        XCTAssertEqual(ctx.windowTitle, "Google")
        XCTAssertEqual(ctx.url, "https://google.com")
        XCTAssertEqual(ctx.recentApps, ["VS Code", "Safari"])
    }

    // MARK: - Helpers

    private func makeContext(
        app: String,
        bundleId: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        recentApps: [String] = []
    ) -> ProcedureMatcher.ActivityContext {
        ProcedureMatcher.ActivityContext(
            currentApp: app,
            currentBundleId: bundleId,
            windowTitle: windowTitle,
            url: url,
            recentApps: recentApps
        )
    }

    private func makeProcedure(
        id: String = "proc-test",
        name: String = "Test Procedure",
        sourceApp: String = "TestApp",
        sourceBundleId: String = "com.test.app",
        tags: [String] = ["test"]
    ) -> ProcedureTemplate {
        ProcedureTemplate(
            id: id,
            name: name,
            description: "A test procedure",
            parameters: [],
            steps: [
                ProcedureStep(
                    index: 0,
                    intent: "Click button",
                    actionType: .click(x: 100, y: 100, button: "left", count: 1),
                    targetLocator: nil,
                    targetDescription: "Button",
                    parameterSubstitutions: [:],
                    expectedPostCondition: nil,
                    maxRetries: 0,
                    timeoutSeconds: 1.0
                )
            ],
            createdAt: CaptureSessionClock.wallMicros(),
            updatedAt: CaptureSessionClock.wallMicros(),
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId,
            tags: tags,
            executionCount: 0,
            lastExecutedAt: nil
        )
    }
}
