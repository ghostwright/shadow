import Foundation
import MLX
import MLXEmbedders
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LocalTextEmbedder")

/// Local text embedding model using MLXEmbedders for semantic search.
///
/// Uses nomic-embed-text-v1.5 (768 dimensions, ~250 MB, 8192 token context) to
/// generate text embeddings that improve semantic search quality beyond what
/// MobileCLIP provides. MobileCLIP is a CLIP model — great for image-text matching
/// but suboptimal for pure text semantic search. A dedicated text embedding model
/// significantly outperforms CLIP for searching transcripts, OCR text, and summaries.
///
/// Actor isolation serializes all access to the mutable model state. The model is
/// lazy-loaded on first embed() call and unloaded after idle timeout or on demand.
///
/// **Not integrated into the existing EmbeddingWorker pipeline.** The CLIP pipeline
/// (512-dim) continues unchanged. Integration with the Rust vector storage (supporting
/// dual embedding dimensions) is a separate task. This actor provides the embedding
/// capability; wiring it into the search pipeline comes later.
actor LocalTextEmbedder {

    /// Embedding dimensionality for nomic-embed-text-v1.5.
    static let dimensions = 768

    /// Loaded embedding model container. Nil when not loaded.
    private var container: MLXEmbedders.ModelContainer?

    /// Timestamp of the last embed() call. Used by idle timer.
    private var lastUsed: Date?

    /// Idle timer task — unloads model after 10 minutes of inactivity.
    private var idleTimerTask: Task<Void, Never>?

    /// Idle timeout interval in seconds. Default: 600 (10 minutes).
    private let idleTimeout: TimeInterval

    /// Whether the embedding model is provisioned on disk.
    ///
    /// Synchronous file check — safe for nonisolated access because it only
    /// reads immutable state (the model spec) and the filesystem.
    nonisolated var isAvailable: Bool {
        LocalModelRegistry.isDownloaded(LocalModelRegistry.embedDefault)
    }

    /// Initialize the embedder.
    ///
    /// Does not load the model — loading is deferred to the first embed() call.
    ///
    /// - Parameter idleTimeout: Seconds of inactivity before unloading. Default: 600 (10 min).
    init(idleTimeout: TimeInterval = 600) {
        self.idleTimeout = idleTimeout
    }

    // MARK: - Public API

    /// Generate embeddings for a batch of texts.
    ///
    /// Loads the model on first call. Each text is independently tokenized and
    /// embedded. Results are L2-normalized 768-dim float vectors.
    ///
    /// - Parameter texts: Array of text strings to embed.
    /// - Returns: Array of embedding vectors, one per input text.
    /// - Throws: If the model cannot be loaded or inference fails.
    func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let startTime = CFAbsoluteTimeGetCurrent()
        DiagnosticsStore.shared.increment("embed_local_attempt_total")
        DiagnosticsStore.shared.setGauge("embed_local_batch_size", value: Double(texts.count))

        let container = try await ensureLoaded()

        var results: [[Float]] = []
        results.reserveCapacity(texts.count)

        for text in texts {
            let vector = try await embedSingle(text: text, container: container)
            results.append(vector)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        DiagnosticsStore.shared.increment("embed_local_success_total")
        DiagnosticsStore.shared.recordLatency("embed_local_latency_ms", ms: elapsed)

        logger.info("Embedded \(texts.count) text(s) in \(String(format: "%.0f", elapsed))ms (\(String(format: "%.1f", elapsed / Double(texts.count)))ms/text)")

        return results
    }

    /// Generate a single embedding.
    ///
    /// Convenience wrapper around batch embed for a single text.
    ///
    /// - Parameter text: The text to embed.
    /// - Returns: A 768-dim L2-normalized float vector.
    /// - Throws: If the model cannot be loaded or inference fails.
    func embed(text: String) async throws -> [Float] {
        let results = try await embed(texts: [text])
        guard let first = results.first else {
            throw LocalTextEmbedderError.emptyResult
        }
        return first
    }

    /// Unload the model and free GPU memory.
    ///
    /// Safe to call when already unloaded (no-op).
    func unload() {
        guard container != nil else { return }

        container = nil
        lastUsed = nil
        idleTimerTask?.cancel()
        idleTimerTask = nil

        // Force Metal cache release, then restore normal limit
        Memory.clearCache()
        MLXConfiguration.configure()

        DiagnosticsStore.shared.setGauge("embed_local_available", value: 0)
        logger.info("Embedding model unloaded")
    }

    // MARK: - Model Loading

    /// Ensure the embedding model is loaded. Lazy-loads on first call.
    private func ensureLoaded() async throws -> MLXEmbedders.ModelContainer {
        lastUsed = Date()
        resetIdleTimer()

        if let existing = container {
            return existing
        }

        return try await loadModel()
    }

    /// Load the embedding model from disk.
    private func loadModel() async throws -> MLXEmbedders.ModelContainer {
        let spec = LocalModelRegistry.embedDefault
        let modelURL = LocalModelRegistry.modelPath(for: spec).resolvingSymlinksInPath()

        guard isAvailable else {
            DiagnosticsStore.shared.increment("embed_local_fail_total")
            throw LocalTextEmbedderError.modelNotProvisioned(path: modelURL.path)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("Loading embedding model: \(spec.localDirectoryName) from \(modelURL.path)")

        do {
            let configuration = MLXEmbedders.ModelConfiguration(directory: modelURL)
            let loaded = try await MLXEmbedders.loadModelContainer(
                configuration: configuration
            )

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            self.container = loaded

            DiagnosticsStore.shared.setGauge("embed_local_available", value: 1)
            DiagnosticsStore.shared.recordLatency("embed_local_load_ms", ms: elapsed)

            logger.info("Embedding model loaded: \(spec.localDirectoryName) in \(String(format: "%.0f", elapsed))ms")

            return loaded
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            DiagnosticsStore.shared.increment("embed_local_fail_total")
            logger.error("Failed to load embedding model: \(error, privacy: .public) (\(String(format: "%.0f", elapsed))ms)")
            throw LocalTextEmbedderError.loadFailed(
                model: spec.localDirectoryName,
                underlying: error.localizedDescription
            )
        }
    }

    // MARK: - Embedding Inference

    /// Run a single text through the embedding model.
    ///
    /// The flow:
    /// 1. Tokenize the text using the model's tokenizer
    /// 2. Run the model forward pass to get hidden states
    /// 3. Apply pooling (mean pooling for nomic) with L2 normalization
    /// 4. Convert MLXArray result to [Float]
    private func embedSingle(
        text: String,
        container: MLXEmbedders.ModelContainer
    ) async throws -> [Float] {
        let vector: [Float] = await container.perform { model, tokenizer, pooler in
            // Tokenize
            let encoded = tokenizer.encode(text: text)
            let inputIds = MLXArray(encoded).expandedDimensions(axis: 0)
            let attentionMask = MLXArray.ones(like: inputIds)

            // Forward pass
            let output = model(
                inputIds,
                positionIds: nil,
                tokenTypeIds: nil,
                attentionMask: attentionMask
            )

            // Pool and normalize
            let pooled = pooler(
                output,
                mask: attentionMask,
                normalize: true
            )

            // Force evaluation before crossing actor boundary
            eval(pooled)

            // Convert MLXArray to [Float]
            // pooled shape: [1, dimensions] — squeeze the batch dimension
            let squeezed = pooled.squeezed(axis: 0)
            let floats: [Float] = squeezed.asArray(Float.self)

            return floats
        }

        guard vector.count == Self.dimensions else {
            DiagnosticsStore.shared.increment("embed_local_fail_total")
            throw LocalTextEmbedderError.dimensionMismatch(
                expected: Self.dimensions,
                actual: vector.count
            )
        }

        return vector
    }

    // MARK: - Idle Timer

    /// Reset the idle timer. Called on every ensureLoaded().
    private func resetIdleTimer() {
        idleTimerTask?.cancel()

        idleTimerTask = Task { [weak self, idleTimeout] in
            do {
                try await Task.sleep(nanoseconds: UInt64(idleTimeout * 1_000_000_000))
            } catch {
                return // Cancelled — new timer was started
            }

            guard let self else { return }
            let lastUsedDate = await self.lastUsed ?? .distantPast
            let elapsed = Date().timeIntervalSince(lastUsedDate)
            if elapsed >= idleTimeout {
                await self.unload()
                logger.info("Embedding model unloaded after \(Int(idleTimeout))s idle timeout")
            }
        }
    }
}

// MARK: - Error Types

/// Errors specific to the local text embedding pipeline.
enum LocalTextEmbedderError: LocalizedError {
    case modelNotProvisioned(path: String)
    case loadFailed(model: String, underlying: String)
    case dimensionMismatch(expected: Int, actual: Int)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .modelNotProvisioned(let path):
            return "Embedding model not provisioned at \(path). Run: python3 scripts/provision-llm-models.py --tier embed"
        case .loadFailed(let model, let underlying):
            return "Failed to load embedding model \(model): \(underlying)"
        case .dimensionMismatch(let expected, let actual):
            return "Embedding dimension mismatch: expected \(expected), got \(actual)"
        case .emptyResult:
            return "Embedding produced no result"
        }
    }
}
