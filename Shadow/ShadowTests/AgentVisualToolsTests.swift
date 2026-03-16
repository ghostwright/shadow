import XCTest
@testable import Shadow

/// Create a SearchResult with visual sourceKind/matchReason.
private func makeVisualResult(
    ts: UInt64 = 1_000_000,
    score: Float = 0.8,
    app: String = "Safari",
    title: String = "Charts",
    matchReason: String = "visual",
    sourceKind: String = "visual",
    displayId: UInt32? = 1
) -> SearchResult {
    SearchResult(
        ts: ts, appName: app, windowTitle: title, url: "",
        displayId: displayId, eventType: "frame", score: score,
        matchReason: matchReason, sourceKind: sourceKind,
        snippet: "", audioSegmentId: nil, audioSource: "",
        tsEnd: 0, confidence: nil
    )
}

/// Create a non-visual SearchResult (text/OCR).
private func makeTextResult(ts: UInt64 = 2_000_000, score: Float = 0.6) -> SearchResult {
    SearchResult(
        ts: ts, appName: "Xcode", windowTitle: "main.swift", url: "",
        displayId: 1, eventType: "text", score: score,
        matchReason: "text", sourceKind: "ocr",
        snippet: "some code", audioSegmentId: nil, audioSource: "",
        tsEnd: 0, confidence: nil
    )
}

/// Create a small test CGImage for inspect_screenshots tests.
private func makeTestCGImage(width: Int = 100, height: Int = 100) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

/// Tests for search_visual_memories and inspect_screenshots tools.
final class AgentVisualToolsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DiagnosticsStore.shared.resetCounters()
    }

    // MARK: - search_visual_memories Tests

    // 1. Uses vector path when textEmbedder returns a vector
    func testSearchVisualMemories_usesVectorPath() async throws {
        let callTracker = SendableBox(false)
        let vectorTracker = SendableBox<[Float]?>(nil)

        let tool = AgentTools.searchVisualMemoriesTool(
            textEmbedder: { _ in [0.1, 0.2, 0.3] },
            searcher: { @Sendable _, vec, _ in
                callTracker.value = true
                vectorTracker.value = vec
                return [makeVisualResult()]
            },
            rangeSearcher: { @Sendable _, _, _, _, _ in [] },
            indexer: { 0 }
        )

        let output = try await tool.handler!(["query": .string("chart on screen")])

        XCTAssertTrue(callTracker.value)
        XCTAssertEqual(vectorTracker.value, [0.1, 0.2, 0.3])
        XCTAssertTrue(output.contains("Safari"))
        XCTAssertEqual(DiagnosticsStore.shared.counter("visual_search_tool_call_total"), 1)
    }

    // 2. Filters to visual-only results
    func testSearchVisualMemories_filtersToVisualOnly() async throws {
        let tool = AgentTools.searchVisualMemoriesTool(
            textEmbedder: { _ in [0.1, 0.2] },
            searcher: { @Sendable _, _, _ in
                [
                    makeVisualResult(ts: 1_000, score: 0.9, app: "Safari"),
                    makeTextResult(ts: 2_000, score: 0.8),  // non-visual, should be filtered
                    makeVisualResult(ts: 3_000, score: 0.7, app: "Figma"),
                ]
            },
            rangeSearcher: { @Sendable _, _, _, _, _ in [] },
            indexer: { 0 }
        )

        let output = try await tool.handler!(["query": .string("screenshot")])

        XCTAssertTrue(output.contains("Safari"))
        XCTAssertTrue(output.contains("Figma"))
        XCTAssertFalse(output.contains("Xcode"), "Non-visual result should be excluded")
    }

    // 3. Uses range searcher when startUs + endUs provided
    func testSearchVisualMemories_usesRangeWhenBoundsProvided() async throws {
        let rangeTracker = SendableBox(false)
        let startTracker = SendableBox<UInt64>(0)
        let endTracker = SendableBox<UInt64>(0)

        let tool = AgentTools.searchVisualMemoriesTool(
            textEmbedder: { _ in [0.5] },
            searcher: { @Sendable _, _, _ in [] },
            rangeSearcher: { @Sendable _, _, startUs, endUs, _ in
                rangeTracker.value = true
                startTracker.value = startUs
                endTracker.value = endUs
                return [makeVisualResult()]
            },
            indexer: { 0 }
        )

        let args: [String: AnyCodable] = [
            "query": .string("meeting"),
            "startUs": .int(100_000),
            "endUs": .int(500_000),
        ]
        _ = try await tool.handler!(args)

        XCTAssertTrue(rangeTracker.value)
        XCTAssertEqual(startTracker.value, 100_000)
        XCTAssertEqual(endTracker.value, 500_000)
    }

    // 4. Validates startUs <= endUs
    func testSearchVisualMemories_validatesStartEndOrder() async {
        let tool = AgentTools.searchVisualMemoriesTool(
            textEmbedder: { _ in [0.1] },
            searcher: { @Sendable _, _, _ in [] },
            rangeSearcher: { @Sendable _, _, _, _, _ in [] },
            indexer: { 0 }
        )

        let args: [String: AnyCodable] = [
            "query": .string("chart"),
            "startUs": .int(500_000),
            "endUs": .int(100_000),  // Invalid: startUs > endUs
        ]

        do {
            _ = try await tool.handler!(args)
            XCTFail("Expected ToolError for invalid range")
        } catch let error as ToolError {
            if case .invalidArgument(let name, _) = error {
                XCTAssertEqual(name, "startUs")
            } else {
                XCTFail("Expected invalidArgument, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // 5. Limit and minScore filters work
    func testSearchVisualMemories_limitAndMinScore() async throws {
        let tool = AgentTools.searchVisualMemoriesTool(
            textEmbedder: { _ in [0.1] },
            searcher: { @Sendable _, _, _ in
                [
                    makeVisualResult(ts: 1_000, score: 0.9),
                    makeVisualResult(ts: 2_000, score: 0.7),
                    makeVisualResult(ts: 3_000, score: 0.3),  // below minScore
                    makeVisualResult(ts: 4_000, score: 0.2),  // below minScore
                ]
            },
            rangeSearcher: { @Sendable _, _, _, _, _ in [] },
            indexer: { 0 }
        )

        let args: [String: AnyCodable] = [
            "query": .string("chart"),
            "limit": .int(5),
            "minScore": .double(0.5),
        ]
        let output = try await tool.handler!(args)
        let lines = output.split(separator: "\n")

        // Only 2 results should pass minScore 0.5 filter
        XCTAssertEqual(lines.count, 2)
    }

    // 6. Returns informative message when CLIP unavailable
    func testSearchVisualMemories_gracefulNoCLIP() async throws {
        let tool = AgentTools.searchVisualMemoriesTool(
            textEmbedder: { _ in nil },  // CLIP not loaded
            searcher: { @Sendable _, _, _ in [] },
            rangeSearcher: { @Sendable _, _, _, _, _ in [] },
            indexer: { 0 }
        )

        let output = try await tool.handler!(["query": .string("anything")])
        XCTAssertTrue(output.contains("CLIP models not loaded"))
        XCTAssertTrue(output.contains("search_hybrid"))
    }

    // MARK: - inspect_screenshots Tests

    // 7. Enforces max 4 candidates
    func testInspectScreenshots_enforcesMaxCandidates() async {
        let tool = AgentTools.inspectScreenshotsTool(
            frameExtractor: { @Sendable _, _ in nil }
        )

        let candidates: [AnyCodable] = (0..<5).map { i in
            .dictionary([
                "timestampUs": .int(Int(i) * 1_000_000),
                "displayId": .int(1),
            ])
        }

        do {
            _ = try await tool.imageHandler!(["candidates": .array(candidates)])
            XCTFail("Expected ToolError for >4 candidates")
        } catch let error as ToolError {
            if case .invalidArgument(let name, let detail) = error {
                XCTAssertEqual(name, "candidates")
                XCTAssertTrue(detail.contains("4"))
            } else {
                XCTFail("Expected invalidArgument, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // 8. Handles invalid candidates gracefully
    func testInspectScreenshots_handlesInvalidCandidates() async throws {
        let tool = AgentTools.inspectScreenshotsTool(
            frameExtractor: { @Sendable _, _ in nil }
        )

        let candidates: [AnyCodable] = [
            .dictionary(["timestampUs": .int(1_000_000)]),  // missing displayId
            .string("not a dict"),  // invalid type
            .dictionary(["displayId": .int(1)]),  // missing timestampUs
        ]

        let output = try await tool.imageHandler!(["candidates": .array(candidates)])

        XCTAssertTrue(output.text.contains("skipped"))
        XCTAssertTrue(output.images.isEmpty)
        XCTAssertEqual(DiagnosticsStore.shared.counter("visual_inspect_fail_total"), 1)
    }

    // 9. Returns images in output for valid candidates
    func testInspectScreenshots_returnsImagesInOutput() async throws {
        guard let testImage = makeTestCGImage() else {
            XCTFail("Could not create test CGImage")
            return
        }

        let tool = AgentTools.inspectScreenshotsTool(
            frameExtractor: { @Sendable _, _ in testImage }
        )

        let candidates: [AnyCodable] = [
            .dictionary([
                "timestampUs": .int(1_000_000),
                "displayId": .int(1),
            ]),
            .dictionary([
                "timestampUs": .int(2_000_000),
                "displayId": .int(1),
            ]),
        ]

        let output = try await tool.imageHandler!(["candidates": .array(candidates)])

        XCTAssertEqual(output.images.count, 2)
        XCTAssertEqual(output.images[0].mediaType, "image/jpeg")
        XCTAssertFalse(output.images[0].base64Data.isEmpty)
        XCTAssertTrue(output.text.contains("extracted"))
        XCTAssertEqual(DiagnosticsStore.shared.counter("visual_images_encoded_total"), 2)
        XCTAssertEqual(DiagnosticsStore.shared.counter("visual_inspect_tool_call_total"), 1)
    }

    // 10. encodeFrameAsJPEG resizes images wider than maxWidth
    func testEncodeFrameAsJPEG_resizesLargeImages() {
        guard let bigImage = makeTestCGImage(width: 1920, height: 1080) else {
            XCTFail("Could not create test image")
            return
        }

        let jpegData = AgentTools.encodeFrameAsJPEG(bigImage, maxWidth: 768, quality: 0.5)
        XCTAssertNotNil(jpegData)
        if let data = jpegData {
            XCTAssertTrue(data.count > 0)
            XCTAssertTrue(data.count < 300_000, "Resized JPEG should be well under 300KB, got \(data.count)")
        }
    }

    // 11. encodeFrameAsJPEG does not upscale small images
    func testEncodeFrameAsJPEG_doesNotUpscaleSmall() {
        guard let smallImage = makeTestCGImage(width: 400, height: 300) else {
            XCTFail("Could not create test image")
            return
        }

        let jpegData = AgentTools.encodeFrameAsJPEG(smallImage, maxWidth: 768, quality: 0.5)
        XCTAssertNotNil(jpegData)
    }

    // 12. Missing candidates argument throws missingArgument
    func testInspectScreenshots_missingCandidatesThrows() async {
        let tool = AgentTools.inspectScreenshotsTool(
            frameExtractor: { @Sendable _, _ in nil }
        )

        do {
            _ = try await tool.imageHandler!([:])
            XCTFail("Expected ToolError for missing candidates")
        } catch let error as ToolError {
            if case .missingArgument(let name) = error {
                XCTAssertEqual(name, "candidates")
            } else {
                XCTFail("Expected missingArgument, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Sendable Tracker

/// Thread-safe mutable box for tracking values in @Sendable closures during tests.
private final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
