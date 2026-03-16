import AppKit
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "VisionLLMProvider")

/// On-device Vision Language Model provider for screenshot understanding.
///
/// Uses Qwen2.5-VL via MLXVLM to analyze screenshots with full visual comprehension
/// that goes beyond OCR — recognizing UI layout, charts, images, visual context,
/// and semantic meaning from screen captures.
///
/// The VLM model is loaded lazily on first analysis request, and unloaded after
/// an idle timeout (default 10 minutes) to free GPU memory. Memory pressure
/// triggers immediate unload.
///
/// Lifecycle management delegates to `LocalModelLifecycle`, which handles
/// mutual exclusion on constrained hardware (<48 GB RAM), idle timers,
/// and memory pressure response. The vision tier shares the lifecycle pool
/// with the text LLM tiers.
///
/// The provider accepts `CGImage` screenshots directly and converts them to
/// temporary JPEG files for the MLXVLM pipeline. Temporary files are cleaned
/// up after analysis completes.
///
/// Actor isolation serializes `analyze()` calls and protects mutable state.
actor VisionLLMProvider {

    /// Lifecycle manager — shared with LocalLLMProvider for mutual exclusion.
    private let lifecycle: LocalModelLifecycle

    /// Model spec for the vision model.
    private let spec: LocalModelSpec

    // MARK: - Init

    /// Initialize the VLM provider.
    ///
    /// - Parameter lifecycle: Shared lifecycle manager. Pass the same instance
    ///   used by `LocalLLMProvider` so mutual exclusion and memory pressure
    ///   coordination work across text and vision models.
    /// - Parameter spec: Vision model spec. Defaults to `LocalModelRegistry.visionDefault`.
    init(
        lifecycle: LocalModelLifecycle,
        spec: LocalModelSpec = LocalModelRegistry.visionDefault
    ) {
        self.lifecycle = lifecycle
        self.spec = spec
    }

    // MARK: - Availability

    /// Whether the VLM model is provisioned on disk.
    ///
    /// Synchronous file check — safe to call from any isolation context.
    /// Returns true if the model directory exists and contains weight files.
    nonisolated var isAvailable: Bool {
        LocalModelRegistry.isDownloaded(spec)
    }

    // MARK: - Analysis

    /// Analyze a screenshot with a natural language query.
    ///
    /// Loads the VLM model if not already loaded (lazy loading via lifecycle manager).
    /// Converts the CGImage to a temporary JPEG file, sends it through the VLM pipeline,
    /// and returns the model's textual analysis.
    ///
    /// - Parameters:
    ///   - image: The screenshot to analyze.
    ///   - query: The question or instruction about the screenshot.
    /// - Returns: The model's textual analysis of the screenshot.
    /// - Throws: `LLMProviderError` if the model is not provisioned or generation fails.
    func analyze(image: CGImage, query: String) async throws -> String {
        DiagnosticsStore.shared.increment("vlm_attempt_total")
        let startTime = CFAbsoluteTimeGetCurrent()

        guard isAvailable else {
            DiagnosticsStore.shared.increment("vlm_fail_total")
            throw LLMProviderError.unavailable(
                reason: "Vision model not provisioned: \(spec.localDirectoryName)"
            )
        }

        // 1. Load the model via the shared lifecycle manager
        let container: ModelContainer
        do {
            container = try await lifecycle.ensureLoaded(tier: .vision)
        } catch {
            DiagnosticsStore.shared.increment("vlm_fail_total")
            logger.error("VLM model load failed: \(error, privacy: .public)")
            throw error
        }

        DiagnosticsStore.shared.setGauge("vlm_model_loaded", value: 1)

        // 2. Convert CGImage to a temporary JPEG file for the VLM pipeline
        let tempURL: URL
        do {
            tempURL = try saveTemporaryJPEG(image)
        } catch {
            DiagnosticsStore.shared.increment("vlm_fail_total")
            logger.error("Failed to encode screenshot as JPEG: \(error, privacy: .public)")
            throw LLMProviderError.transientFailure(
                underlying: "Failed to encode screenshot: \(error.localizedDescription)"
            )
        }
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // 3. Create a fresh ChatSession and generate the response
        var genParams = GenerateParameters()
        genParams.maxTokens = 1024
        genParams.temperature = 0.2

        let session = ChatSession(
            container,
            generateParameters: genParams
        )

        let responseText: String
        do {
            var fullText = ""
            let stream = session.streamDetails(
                to: query,
                images: [.url(tempURL)],
                videos: []
            )

            for try await generation in stream {
                switch generation {
                case .chunk(let text):
                    fullText += text
                case .info:
                    break
                case .toolCall:
                    break
                }
            }
            responseText = fullText
        } catch {
            DiagnosticsStore.shared.increment("vlm_fail_total")
            logger.error("VLM generation failed: \(error, privacy: .public)")
            throw LLMProviderError.transientFailure(
                underlying: "VLM generation failed: \(error.localizedDescription)"
            )
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        DiagnosticsStore.shared.increment("vlm_success_total")
        DiagnosticsStore.shared.recordLatency("vlm_latency_ms", ms: elapsed)

        logger.info("VLM analysis: \(responseText.count) chars, \(String(format: "%.0f", elapsed))ms")

        return responseText
    }

    /// Unload the VLM model and free GPU memory.
    ///
    /// Safe to call when not loaded (no-op via lifecycle manager).
    func unload() async {
        await lifecycle.unload(tier: .vision)
        DiagnosticsStore.shared.setGauge("vlm_model_loaded", value: 0)
    }

    // MARK: - Image Encoding

    /// Convert a CGImage to a temporary JPEG file.
    ///
    /// The MLXVLM pipeline accepts image URLs. This creates a temporary file
    /// in the system temp directory that the caller must clean up after use.
    ///
    /// - Parameter cgImage: The image to encode.
    /// - Returns: URL to the temporary JPEG file.
    /// - Throws: If the image cannot be encoded or written.
    private func saveTemporaryJPEG(_ cgImage: CGImage) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")

        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        guard let tiffData = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let jpegData = rep.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.8]
              )
        else {
            throw VisionLLMProviderError.imageEncodingFailed
        }

        try jpegData.write(to: tempURL)
        return tempURL
    }
}

// MARK: - Errors

enum VisionLLMProviderError: Error, LocalizedError {
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Failed to encode CGImage as JPEG for VLM analysis"
        }
    }
}
