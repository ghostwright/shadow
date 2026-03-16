import AppKit
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LocalGroundingModel")

/// On-device UI element grounding using a small VLM (ShowUI-2B).
///
/// Given a natural language instruction and a screenshot, predicts the screen
/// coordinates of the target UI element. This is the fast local alternative
/// to sending screenshots to a cloud model for grounding.
///
/// The model is loaded lazily via the shared `LocalModelLifecycle` manager
/// and automatically unloaded after an idle timeout.
///
/// Mimicry Phase B: Local Grounding Model.
actor LocalGroundingModel {

    /// Shared lifecycle manager for model loading/unloading.
    private let lifecycle: LocalModelLifecycle

    /// Model spec for the grounding model.
    private let spec: LocalModelSpec

    /// Number of successful grounding predictions this session.
    private(set) var groundingSuccessCount: Int = 0

    /// Number of failed grounding predictions this session.
    private(set) var groundingFailCount: Int = 0

    // MARK: - Init

    init(
        lifecycle: LocalModelLifecycle,
        spec: LocalModelSpec = LocalModelRegistry.groundingDefault
    ) {
        self.lifecycle = lifecycle
        self.spec = spec
    }

    // MARK: - Availability

    /// Whether the grounding model is provisioned on disk.
    nonisolated var isAvailable: Bool {
        LocalModelRegistry.isDownloaded(spec)
    }

    // MARK: - Grounding

    /// Find the target element on screen given a natural language instruction.
    ///
    /// Takes a screenshot and an instruction (e.g., "Click the Compose button"),
    /// runs it through the local VLM, and returns predicted click coordinates.
    ///
    /// - Parameters:
    ///   - instruction: Natural language description of what to find (e.g., "Click the Send button")
    ///   - screenshot: The current screen frame as a CGImage
    ///   - screenSize: The logical screen size (points) for coordinate normalization
    /// - Returns: A `GroundingResult` with predicted coordinates and confidence
    /// - Throws: If the model is not available or inference fails
    func ground(
        instruction: String,
        screenshot: CGImage,
        screenSize: CGSize
    ) async throws -> GroundingResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        DiagnosticsStore.shared.increment("grounding_attempt_total")

        guard isAvailable else {
            groundingFailCount += 1
            DiagnosticsStore.shared.increment("grounding_fail_total")
            throw GroundingError.modelNotAvailable
        }

        // Load the model via the shared lifecycle manager
        let container: ModelContainer
        do {
            container = try await lifecycle.ensureLoaded(tier: .grounding)
        } catch {
            groundingFailCount += 1
            DiagnosticsStore.shared.increment("grounding_fail_total")
            logger.error("Grounding model load failed: \(error, privacy: .public)")
            throw GroundingError.modelLoadFailed(error.localizedDescription)
        }

        // Convert screenshot to temporary JPEG
        let tempURL: URL
        do {
            tempURL = try saveTemporaryJPEG(screenshot, quality: 0.85)
        } catch {
            groundingFailCount += 1
            DiagnosticsStore.shared.increment("grounding_fail_total")
            throw GroundingError.screenshotEncodingFailed
        }
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Build the grounding prompt using ShowUI-2B's EXACT format.
        //
        // CRITICAL: ShowUI-2B requires the system instruction as TEXT in the USER message,
        // NOT as a separate system message. The format is:
        //   user: [system_text] [image] [query_text]
        //
        // Using ChatSession(instructions:) creates a system message, which causes
        // ShowUI-2B to immediately output EOS (empty response). Verified empirically
        // in Python: wrong format → empty output, correct format → [x, y] coordinates.
        let systemText = "Based on the screenshot of the page, I give a text description and you give its corresponding location. The coordinate represents a clickable location [x, y] for an element, which is a relative coordinate on the screenshot, scaled from 0 to 1."

        // Combine system text + query into one user prompt (image is injected by ChatSession)
        let prompt = "\(systemText)\n\(instruction)"

        // Run inference
        var genParams = GenerateParameters()
        genParams.maxTokens = 128
        genParams.temperature = 0.0  // Deterministic for coordinate prediction

        // CRITICAL: Resize the screenshot to fit within ShowUI-2B's max_pixels budget.
        // Full Retina screenshots (3456x2234 = 7.7M pixels) cause a 49.5 GB GPU allocation
        // that exceeds Metal's buffer limit. ShowUI-2B's max_pixels = 1344*28*28 = 1,053,696.
        // Resizing to ~1280x828 keeps total pixels under budget while preserving enough
        // detail for UI element grounding. Verified: 3.2s inference, correct coordinates.
        let session = ChatSession(
            container,
            generateParameters: genParams,
            processing: .init(resize: CGSize(width: 1280, height: 828))
        )

        let responseText: String
        do {
            var fullText = ""
            let stream = session.streamDetails(
                to: prompt,
                images: [.url(tempURL)],
                videos: []
            )

            for try await generation in stream {
                switch generation {
                case .chunk(let text):
                    fullText += text
                case .info, .toolCall:
                    break
                }
            }
            responseText = fullText
            logger.notice("[MIMICRY-V2] VLM raw response for '\(instruction, privacy: .public)': '\(fullText, privacy: .public)'")
        } catch {
            groundingFailCount += 1
            DiagnosticsStore.shared.increment("grounding_fail_total")
            logger.error("[MIMICRY-V2] Grounding inference failed: \(error, privacy: .public)")
            throw GroundingError.inferenceFailed(error.localizedDescription)
        }

        // Parse the response to extract coordinates
        let result = parseGroundingResponse(
            responseText,
            screenSize: screenSize,
            instruction: instruction
        )

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        if result.confidence > 0.3 {
            groundingSuccessCount += 1
            DiagnosticsStore.shared.increment("grounding_success_total")
        } else {
            groundingFailCount += 1
            DiagnosticsStore.shared.increment("grounding_low_confidence_total")
        }

        DiagnosticsStore.shared.recordLatency("grounding_latency_ms", ms: elapsed)
        logger.notice("[MIMICRY-V2] Grounding: '\(instruction, privacy: .public)' -> (\(String(format: "%.0f", result.x)), \(String(format: "%.0f", result.y))) confidence=\(String(format: "%.2f", result.confidence)) \(String(format: "%.0f", elapsed))ms")

        return result
    }

    /// Unload the grounding model to free GPU memory.
    func unload() async {
        await lifecycle.unload(tier: .grounding)
    }

    // MARK: - Response Parsing

    /// Parse the VLM's grounding response to extract click coordinates.
    ///
    /// ShowUI-2B outputs coordinates in `[x, y]` format where x,y are 0.0-1.0
    /// normalized values relative to the image dimensions. The parser also handles
    /// fallback formats for robustness:
    /// - `[0.35, 0.72]` — ShowUI-2B native format (primary)
    /// - `(0.35, 0.72)` — Parenthesized tuple variant
    /// - `click(x=0.35, y=0.72)` — Explicit click format (alternative VLMs)
    private func parseGroundingResponse(
        _ response: String,
        screenSize: CGSize,
        instruction: String
    ) -> GroundingResult {
        // Primary: ShowUI-2B native format [x, y] or (x, y)
        // This is the format ShowUI-2B actually produces.
        if let match = response.firstMatch(of: /[\(\[]\s*([\d.]+)\s*,\s*([\d.]+)\s*[\)\]]/) {
            if let v1 = Double(match.1), let v2 = Double(match.2) {
                let (nx, ny): (Double, Double)
                let confidence: Double
                if v1 <= 1.0 && v2 <= 1.0 {
                    // Normalized coordinates — this is the expected ShowUI output
                    nx = v1; ny = v2
                    confidence = 0.8
                } else {
                    // Pixel coordinates — normalize by screen size
                    nx = v1 / screenSize.width
                    ny = v2 / screenSize.height
                    confidence = 0.6
                }
                let x = nx * screenSize.width
                let y = ny * screenSize.height
                return GroundingResult(
                    x: x, y: y,
                    normalizedX: nx, normalizedY: ny,
                    confidence: confidence,
                    rawResponse: response,
                    instruction: instruction
                )
            }
        }

        // Fallback: click(x=0.35, y=0.72) format
        if let match = response.firstMatch(of: /click\(\s*x\s*=\s*([\d.]+)\s*,\s*y\s*=\s*([\d.]+)\s*\)/) {
            if let nx = Double(match.1), let ny = Double(match.2) {
                let x = nx * screenSize.width
                let y = ny * screenSize.height
                return GroundingResult(
                    x: x, y: y,
                    normalizedX: nx, normalizedY: ny,
                    confidence: 0.8,
                    rawResponse: response,
                    instruction: instruction
                )
            }
        }

        // Failed to parse — return center with zero confidence
        logger.warning("Failed to parse grounding response: '\(response.prefix(200), privacy: .public)'")
        return GroundingResult(
            x: screenSize.width / 2,
            y: screenSize.height / 2,
            normalizedX: 0.5,
            normalizedY: 0.5,
            confidence: 0.0,
            rawResponse: response,
            instruction: instruction
        )
    }

    // MARK: - Image Encoding

    /// Convert a CGImage to a temporary JPEG file for the VLM pipeline.
    private func saveTemporaryJPEG(_ cgImage: CGImage, quality: Double = 0.85) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grounding-\(UUID().uuidString).jpg")

        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        guard let tiffData = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let jpegData = rep.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: NSNumber(value: quality)]
              )
        else {
            throw GroundingError.screenshotEncodingFailed
        }

        try jpegData.write(to: tempURL)
        return tempURL
    }
}

// MARK: - Result Type

/// Result of a grounding prediction.
struct GroundingResult: Sendable {
    /// Predicted X coordinate in screen points.
    let x: Double
    /// Predicted Y coordinate in screen points.
    let y: Double
    /// Normalized X coordinate (0.0-1.0 relative to screen width).
    let normalizedX: Double
    /// Normalized Y coordinate (0.0-1.0 relative to screen height).
    let normalizedY: Double
    /// Confidence score (0.0-1.0). Below 0.3 is considered unreliable.
    let confidence: Double
    /// Raw model response text (for debugging).
    let rawResponse: String
    /// The instruction that was grounded (for logging).
    let instruction: String

    /// CGPoint for use with InputSynthesizer click actions.
    var point: CGPoint { CGPoint(x: x, y: y) }
}

// MARK: - Errors

enum GroundingError: Error, LocalizedError {
    case modelNotAvailable
    case modelLoadFailed(String)
    case screenshotEncodingFailed
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotAvailable:
            return "Grounding model (ShowUI-2B) is not provisioned. Run provision-grounding-models.py."
        case .modelLoadFailed(let reason):
            return "Failed to load grounding model: \(reason)"
        case .screenshotEncodingFailed:
            return "Failed to encode screenshot as JPEG for grounding model"
        case .inferenceFailed(let reason):
            return "Grounding inference failed: \(reason)"
        }
    }
}
