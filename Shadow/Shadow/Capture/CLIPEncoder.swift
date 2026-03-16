import Accelerate
@preconcurrency import CoreML
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "CLIPEncoder")

/// Loads and runs MobileCLIP-S2 CoreML models for image and text embedding.
///
/// Discovers model assets from the app bundle's Resources/Models directory.
/// Fails gracefully to nil if models are missing or fail to load.
///
/// Thread-safe: MLModel.prediction is thread-safe per Apple docs.
/// All state is immutable after init. MLModel is not Sendable-annotated by Apple
/// but is documented as thread-safe for prediction calls.
final class CLIPEncoder: @unchecked Sendable {
    /// Model identifier for cache keys and diagnostics.
    let modelId: String

    /// Embedding dimensionality (512 for MobileCLIP-S2).
    let embeddingDimension: Int = 512

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer

    /// Output feature name for embeddings (varies between model sources).
    private let imageOutputName: String
    private let textOutputName: String

    /// Attempt to load CLIP models from the app bundle.
    /// Returns nil if any required asset is missing or fails to load.
    ///
    /// Xcode compiles .mlpackage to .mlmodelc during build. The compiled models
    /// live at Bundle.main.resourceURL (not in a Models/ subdirectory).
    /// The tokenizer JSON is also copied to the bundle root.
    init?() {
        guard let resourceURL = Bundle.main.resourceURL else {
            logger.warning("No resource URL in app bundle")
            return nil
        }

        // Xcode compiles mlpackage → mlmodelc during build
        let imageURL = resourceURL.appendingPathComponent("MobileCLIPImageEncoder.mlmodelc")
        let textURL = resourceURL.appendingPathComponent("MobileCLIPTextEncoder.mlmodelc")
        let tokenizerURL = resourceURL.appendingPathComponent("clip_tokenizer.json")

        // Check all assets exist before attempting load
        let fm = FileManager.default
        guard fm.fileExists(atPath: imageURL.path),
              fm.fileExists(atPath: textURL.path),
              fm.fileExists(atPath: tokenizerURL.path)
        else {
            logger.info("CLIP model assets not found in bundle — vector search disabled")
            return nil
        }

        // Load tokenizer
        guard let tokenizer = CLIPTokenizer(url: tokenizerURL) else {
            logger.error("Failed to load CLIP tokenizer")
            DiagnosticsStore.shared.increment("model_load_fail_total")
            return nil
        }
        self.tokenizer = tokenizer
        self.modelId = tokenizer.modelId

        // Load CoreML models (already compiled by Xcode)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        do {
            self.imageModel = try MLModel(contentsOf: imageURL, configuration: config)
            logger.info("CLIP image encoder loaded")
        } catch {
            logger.error("Failed to load CLIP image encoder: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("model_load_fail_total")
            return nil
        }

        do {
            self.textModel = try MLModel(contentsOf: textURL, configuration: config)
            logger.info("CLIP text encoder loaded")
        } catch {
            logger.error("Failed to load CLIP text encoder: \(error, privacy: .public)")
            DiagnosticsStore.shared.increment("model_load_fail_total")
            return nil
        }

        // Detect output names (Apple's pre-exported models use "final_emb_1",
        // our conversion script uses "embedding")
        let imageOutputs = self.imageModel.modelDescription.outputDescriptionsByName
        if imageOutputs["embedding"] != nil {
            self.imageOutputName = "embedding"
        } else if imageOutputs["final_emb_1"] != nil {
            self.imageOutputName = "final_emb_1"
        } else {
            let available = Array(imageOutputs.keys)
            logger.error("Image encoder has no recognized output name. Available: \(available)")
            DiagnosticsStore.shared.increment("model_load_fail_total")
            return nil
        }

        let textOutputs = self.textModel.modelDescription.outputDescriptionsByName
        if textOutputs["embedding"] != nil {
            self.textOutputName = "embedding"
        } else if textOutputs["final_emb_1"] != nil {
            self.textOutputName = "final_emb_1"
        } else {
            let available = Array(textOutputs.keys)
            logger.error("Text encoder has no recognized output name. Available: \(available)")
            DiagnosticsStore.shared.increment("model_load_fail_total")
            return nil
        }

        DiagnosticsStore.shared.increment("model_load_success_total")
        logger.info("CLIP encoder ready: \(self.modelId), image_out=\(self.imageOutputName), text_out=\(self.textOutputName)")
    }

    // MARK: - Image Embedding

    /// Generate a 512-dim L2-normalized embedding from a CGImage.
    /// Returns nil on inference failure.
    func embedImage(_ image: CGImage) -> [Float]? {
        do {
            // CoreML ImageType input handles resize + normalization per model spec
            let pixelBuffer = try createPixelBuffer(from: image, width: 256, height: 256)
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: pixelBuffer),
            ])

            let output = try imageModel.prediction(from: input)

            guard let embeddingValue = output.featureValue(for: imageOutputName),
                  let multiArray = embeddingValue.multiArrayValue
            else {
                logger.error("Image encoder output missing '\(self.imageOutputName)'")
                return nil
            }

            return extractAndNormalize(multiArray)
        } catch {
            logger.error("Image embedding failed: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Text Embedding

    /// Generate a 512-dim L2-normalized embedding from a text query.
    /// Returns nil on inference failure.
    func embedText(_ text: String) -> [Float]? {
        let tokenIds = tokenizer.tokenize(text)

        do {
            // Create Int32 multi-array [1, 77]
            let shape: [NSNumber] = [1, NSNumber(value: tokenizer.contextLength)]
            let inputArray = try MLMultiArray(shape: shape, dataType: .int32)

            for (i, token) in tokenIds.enumerated() {
                inputArray[i] = NSNumber(value: token)
            }

            // Detect input name from model description
            let inputName: String
            let inputDescs = textModel.modelDescription.inputDescriptionsByName
            if inputDescs["text"] != nil {
                inputName = "text"
            } else if inputDescs["input_ids"] != nil {
                inputName = "input_ids"
            } else {
                inputName = inputDescs.keys.first ?? "text"
            }

            let input = try MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(multiArray: inputArray),
            ])

            let output = try textModel.prediction(from: input)

            guard let embeddingValue = output.featureValue(for: textOutputName),
                  let multiArray = embeddingValue.multiArrayValue
            else {
                logger.error("Text encoder output missing '\(self.textOutputName)'")
                return nil
            }

            return extractAndNormalize(multiArray)
        } catch {
            logger.error("Text embedding failed: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Helpers

    /// Extract float values from MLMultiArray and L2-normalize.
    ///
    /// Handles both Float32 and Float16 output dtypes. CoreML may produce Float16
    /// when running on Neural Engine even if the model spec says Float32.
    private func extractAndNormalize(_ multiArray: MLMultiArray) -> [Float]? {
        let count = multiArray.count
        guard count >= embeddingDimension else {
            logger.error("Embedding dimension mismatch: got \(count), expected >= \(self.embeddingDimension)")
            return nil
        }

        // Extract the last embeddingDimension values (handles [1, 512] shape)
        let offset = count - embeddingDimension
        var vector = [Float](repeating: 0, count: embeddingDimension)

        switch multiArray.dataType {
        case .float32:
            let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<embeddingDimension {
                vector[i] = ptr[offset + i]
            }

        case .float16:
            let ptr = multiArray.dataPointer.bindMemory(to: UInt16.self, capacity: count)
            for i in 0..<embeddingDimension {
                var f16 = ptr[offset + i]
                var f32: Float = 0
                // IEEE 754 half→single conversion via vImageConvert
                let err: vImage_Error = withUnsafePointer(to: &f16) { src in
                    withUnsafeMutablePointer(to: &f32) { dst in
                        var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: 1, width: 1, rowBytes: 2)
                        var dstBuf = vImage_Buffer(data: UnsafeMutableRawPointer(dst), height: 1, width: 1, rowBytes: 4)
                        return vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, 0)
                    }
                }
                if err != kvImageNoError {
                    logger.error("Float16→Float32 conversion failed at index \(i), vImage error \(err)")
                    return nil
                }
                vector[i] = f32
            }

        case .double:
            let ptr = multiArray.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<embeddingDimension {
                vector[i] = Float(ptr[offset + i])
            }

        default:
            logger.error("Unsupported MLMultiArray dataType: \(multiArray.dataType.rawValue)")
            return nil
        }

        // L2 normalize
        var normSq: Float = 0
        for v in vector { normSq += v * v }
        let norm = sqrt(normSq)
        guard norm > 1e-10 else { return nil }

        for i in 0..<embeddingDimension {
            vector[i] /= norm
        }

        return vector
    }

    /// Create a CVPixelBuffer from a CGImage, resized to target dimensions.
    private func createPixelBuffer(from image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw CLIPEncoderError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            throw CLIPEncoderError.pixelBufferCreationFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
    }

    private enum CLIPEncoderError: Error {
        case pixelBufferCreationFailed
    }
}
