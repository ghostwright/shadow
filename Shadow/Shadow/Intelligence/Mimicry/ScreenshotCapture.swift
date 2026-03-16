import AppKit
import Foundation
import Vision
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ScreenshotCapture")

/// Provides live screenshot capture and OCR text extraction for the Mimicry V2 vision loop.
///
/// Unlike Shadow's 0.5fps recording pipeline (ScreenRecorder), this captures full-resolution
/// screenshots on demand via `CGWindowListCreateImage`. Used by VisionAgent to:
/// 1. Capture the current screen state for VLM grounding (ShowUI-2B)
/// 2. Capture post-action screenshots for verification
/// 3. Extract visible text via Vision framework OCR for state comparison
///
/// All methods are @MainActor because CGWindowListCreateImage must be called
/// on the main thread for reliable results.
enum ScreenshotCapture {

    // MARK: - Screenshot

    /// Capture a full-resolution screenshot of the current screen.
    ///
    /// Returns a CGImage suitable for VLM inference or JPEG encoding.
    /// Uses `.bestResolution` for maximum fidelity.
    ///
    /// Note: Uses CGWindowListCreateImage which is deprecated in macOS 14.0 in favor
    /// of ScreenCaptureKit. However, ScreenCaptureKit requires async setup with
    /// SCShareableContent enumeration, making it impractical for synchronous single-frame
    /// capture. CGWindowListCreateImage remains the simplest approach for on-demand
    /// screenshots and continues to work in macOS 15+.
    ///
    /// - Returns: A CGImage of the entire screen, or nil if capture fails.
    @MainActor
    static func captureScreen() -> CGImage? {
        guard let screen = NSScreen.main else {
            logger.warning("[MIMICRY-V2] No main screen available for capture")
            return nil
        }

        let screenRect = CGRect(
            x: 0, y: 0,
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )

        let image = CGWindowListCreateImage(
            screenRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        )

        if image == nil {
            logger.warning("[MIMICRY-V2] CGWindowListCreateImage returned nil — Screen Recording permission may be missing")
        }

        return image
    }

    /// Get the logical screen size (points, not pixels).
    @MainActor
    static var screenSize: CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
    }

    // MARK: - Image Resizing

    /// Resize a CGImage so its longest edge is at most `maxEdge` pixels.
    ///
    /// Anthropic's API rejects multi-image requests where any image exceeds 2000px
    /// on either dimension. Full Retina screenshots are 3456x2234, so they must be
    /// downscaled before sending to Haiku.
    ///
    /// - Parameters:
    ///   - image: The source CGImage.
    ///   - maxEdge: Maximum pixels on longest edge. Default 1600 (safe margin under 2000).
    /// - Returns: A resized CGImage, or the original if already small enough.
    static func resize(_ image: CGImage, maxEdge: Int = 1600) -> CGImage? {
        let w = image.width
        let h = image.height
        guard max(w, h) > maxEdge else { return image }

        let scale = Double(maxEdge) / Double(max(w, h))
        let newW = Int(Double(w) * scale)
        let newH = Int(Double(h) * scale)

        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    // MARK: - JPEG Encoding

    /// Encode a CGImage as JPEG data for API transmission.
    ///
    /// Uses 0.7 quality for a good balance between size and fidelity.
    /// A typical 1440p screenshot compresses to ~200-400KB at this quality.
    ///
    /// - Parameters:
    ///   - image: The CGImage to encode.
    ///   - quality: JPEG compression quality (0.0-1.0). Default 0.7.
    /// - Returns: JPEG data, or nil if encoding fails.
    static func encodeJPEG(_ image: CGImage, quality: Double = 0.7) -> Data? {
        let nsImage = NSImage(cgImage: image, size: .zero)
        guard let tiffData = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let jpegData = rep.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: NSNumber(value: quality)]
              )
        else {
            return nil
        }
        return jpegData
    }

    /// Encode a CGImage as base64 JPEG string for API transmission.
    ///
    /// - Parameters:
    ///   - image: The CGImage to encode.
    ///   - quality: JPEG compression quality (0.0-1.0). Default 0.7.
    /// - Returns: Base64-encoded JPEG string, or nil if encoding fails.
    static func encodeBase64JPEG(_ image: CGImage, quality: Double = 0.7) -> String? {
        guard let data = encodeJPEG(image, quality: quality) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - OCR

    /// Extract all visible text from a screenshot using Vision framework OCR.
    ///
    /// Uses `VNRecognizeTextRequest` with `.accurate` recognition level.
    /// Returns the recognized text as a single string with newline separators.
    ///
    /// Performance: ~50-150ms for a full-screen screenshot on M4 Pro.
    ///
    /// - Parameter image: The screenshot to extract text from.
    /// - Returns: All recognized text joined by newlines, or empty string if OCR fails.
    static func extractText(from image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    logger.info("[MIMICRY-V2] OCR failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: "")
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                logger.info("[MIMICRY-V2] VNImageRequestHandler failed: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: "")
            }
        }
    }

    /// Save a CGImage to a temporary JPEG file (for VLM inference pipelines that need a file URL).
    ///
    /// The caller is responsible for cleanup via `FileManager.removeItem(at:)`.
    ///
    /// - Parameters:
    ///   - image: The CGImage to save.
    ///   - quality: JPEG compression quality.
    /// - Returns: URL to the temporary JPEG file, or nil if encoding fails.
    static func saveTemporaryJPEG(_ image: CGImage, quality: Double = 0.85) -> URL? {
        guard let data = encodeJPEG(image, quality: quality) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimicry-v2-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            return url
        } catch {
            logger.warning("[MIMICRY-V2] Failed to write temp JPEG: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
