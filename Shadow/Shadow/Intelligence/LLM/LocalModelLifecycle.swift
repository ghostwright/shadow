import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LocalModelLifecycle")

/// Manages the lifecycle of local MLX models: lazy loading, idle unloading,
/// mutual exclusion on constrained hardware, and memory pressure response.
///
/// Actor isolation serializes all access to the mutable model containers,
/// preventing concurrent loads or use-after-unload races.
///
/// Lifecycle rules:
/// - **Lazy:** Models load on first `ensureLoaded(tier:)`, not at app launch.
/// - **Idle timeout:** Each tier unloads after 10 minutes of no use.
/// - **Mutual exclusion:** On systems with <48 GB RAM, only one model is loaded
///   at a time. Loading a new tier evicts the currently loaded one.
/// - **Memory pressure:** Unloads all models on `.critical` (largest first).
/// - **Clean unload:** Nils the container, zeros the GPU cache, then restores it.
actor LocalModelLifecycle {

    /// Loaded model containers, keyed by tier.
    private var containers: [LocalModelTier: ModelContainer] = [:]

    /// Timestamp of the last `ensureLoaded(tier:)` call per tier. Used by idle timers.
    private var lastUsed: [LocalModelTier: Date] = [:]

    /// Currently running idle timer tasks, keyed by tier.
    private var idleTimerTasks: [LocalModelTier: Task<Void, Never>] = [:]

    /// Idle timeout interval. Defaults to 10 minutes.
    private let idleTimeout: TimeInterval

    /// Tiers that have been unloaded since the last `drainPendingInvalidations()` call.
    /// The owning provider polls this before each `generate()` to invalidate its session
    /// cache for any tiers that were unloaded by idle timer, mutual exclusion, or memory
    /// pressure -- paths that bypass the provider entirely.
    private var pendingInvalidations: Set<LocalModelTier> = []

    /// Memory pressure source — monitors system memory and unloads on critical.
    /// Stored as nonisolated(unsafe) because DispatchSource is not Sendable,
    /// but it's created once in init and only cancelled in deinit. The source's
    /// event handler bridges back to the actor via Task.
    nonisolated(unsafe) private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Whether a specific tier's model is currently loaded.
    func isLoaded(tier: LocalModelTier) -> Bool {
        containers[tier] != nil
    }

    /// Whether ANY model is currently loaded.
    var hasLoadedModel: Bool {
        !containers.isEmpty
    }

    /// Which tiers are currently loaded.
    var loadedTiers: [LocalModelTier] {
        Array(containers.keys)
    }

    /// Initialize the lifecycle manager.
    ///
    /// The lifecycle does not take model specs at init. It looks them up from
    /// `LocalModelRegistry` when loading, since it manages multiple tiers.
    ///
    /// - Parameter idleTimeout: Seconds of inactivity before unloading a tier. Default: 600 (10 min).
    init(idleTimeout: TimeInterval = 600) {
        self.idleTimeout = idleTimeout

        // Memory pressure setup is nonisolated static — safe to call from init.
        // The returned source captures `self` weakly via the event handler.
        self.memoryPressureSource = Self.createMemoryPressureSource(for: self)
    }

    deinit {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    // MARK: - Public API

    /// Get a loaded model container for the requested tier.
    ///
    /// Loads the model if not already loaded. On systems with <48 GB RAM,
    /// enforces mutual exclusion by unloading other tiers first.
    ///
    /// Resets the idle timer for the requested tier on every call. Actor
    /// serialization prevents concurrent loads automatically.
    ///
    /// - Parameter tier: The model tier to load (`.fast` or `.deep`).
    /// - Returns: A loaded `ModelContainer` ready for generation.
    /// - Throws: `LLMProviderError.unavailable` if loading fails.
    func ensureLoaded(tier: LocalModelTier) async throws -> ModelContainer {
        lastUsed[tier] = Date()
        resetIdleTimer(for: tier)

        if let existing = containers[tier] {
            return existing
        }

        // Mutual exclusion on constrained hardware (<48 GB RAM):
        // Only one model loaded at a time. Evict others before loading.
        let systemRAMGB = MLXConfiguration.systemRAMGB
        if systemRAMGB < 48 {
            for (loadedTier, _) in containers where loadedTier != tier {
                logger.info("Mutual exclusion: evicting \(loadedTier.rawValue) tier to load \(tier.rawValue) (\(systemRAMGB)GB RAM)")
                DiagnosticsStore.shared.increment("llm_local_mutual_exclusion_evict_total")
                unload(tier: loadedTier)
            }
        }

        return try await loadModel(tier: tier)
    }

    /// Force unload a specific tier and free GPU memory.
    ///
    /// Safe to call when already unloaded (no-op).
    /// Records the tier in `pendingInvalidations` so the owning provider
    /// can invalidate its session cache on the next `generate()` call.
    func unload(tier: LocalModelTier) {
        guard containers[tier] != nil else { return }

        containers.removeValue(forKey: tier)
        lastUsed.removeValue(forKey: tier)
        idleTimerTasks[tier]?.cancel()
        idleTimerTasks.removeValue(forKey: tier)

        // Record for session cache invalidation by the owning provider.
        pendingInvalidations.insert(tier)

        // Force Metal cache release, then restore normal limit
        Memory.clearCache()
        MLXConfiguration.configure()

        DiagnosticsStore.shared.setGauge("llm_local_\(tier.rawValue)_model_loaded", value: 0)
        logger.info("Model unloaded: tier=\(tier.rawValue)")
    }

    /// Force unload all models and free GPU memory.
    ///
    /// Called during app shutdown. Safe to call when no models are loaded.
    func unloadAll() {
        let tiers = Array(containers.keys)
        for tier in tiers {
            unload(tier: tier)
        }
    }

    /// Return and clear the set of tiers unloaded since the last drain.
    ///
    /// The owning provider calls this before each `generate()` to discover
    /// tiers that were unloaded by idle timer, mutual exclusion, or memory
    /// pressure, and invalidate the corresponding session cache entries.
    func drainPendingInvalidations() -> Set<LocalModelTier> {
        guard !pendingInvalidations.isEmpty else { return [] }
        let drained = pendingInvalidations
        pendingInvalidations.removeAll()
        return drained
    }

    // MARK: - Loading

    /// Whether a tier uses a vision-language model (VLM) vs a text-only LLM.
    ///
    /// VLM tiers must be loaded via `VLMModelFactory` which understands architectures
    /// like `qwen2_vl`, `qwen2_5_vl`, etc. Text-only tiers use `LLMModelFactory`.
    /// Using the wrong factory produces `unsupportedModelType` errors because each
    /// factory's type registry only knows its own architecture set.
    private static func isVLMTier(_ tier: LocalModelTier) -> Bool {
        switch tier {
        case .vision, .grounding: return true
        case .fast, .deep, .embed: return false
        }
    }

    /// Load a model for the given tier from disk.
    private func loadModel(tier: LocalModelTier) async throws -> ModelContainer {
        let spec = Self.spec(for: tier)
        let modelURL = LocalModelRegistry.modelPath(for: spec).resolvingSymlinksInPath()
        let startTime = CFAbsoluteTimeGetCurrent()

        logger.info("Loading model: tier=\(tier.rawValue) \(spec.localDirectoryName) from \(modelURL.path)")

        let loaded: ModelContainer
        do {
            let config = ModelConfiguration(directory: modelURL)
            if Self.isVLMTier(tier) {
                // VLM tiers (vision, grounding) use VLMModelFactory directly.
                // The generic loadModelContainer() free function iterates factories
                // via NSClassFromString trampolines, but silently swallows VLM errors
                // and falls through to the LLM factory — which then fails with
                // "unsupportedModelType" for VLM architectures like qwen2_vl.
                loaded = try await VLMModelFactory.shared.loadContainer(configuration: config)
            } else {
                // Text-only tiers use the generic loader (which resolves to LLMModelFactory).
                loaded = try await loadModelContainer(directory: modelURL)
            }
        } catch {
            logger.error("Failed to load \(tier.rawValue) model: \(error, privacy: .public)")
            throw LLMProviderError.unavailable(
                reason: "Failed to load model \(spec.localDirectoryName): \(error.localizedDescription)"
            )
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        self.containers[tier] = loaded

        // Update diagnostics gauges — tier-specific keys
        DiagnosticsStore.shared.setGauge("llm_local_\(tier.rawValue)_model_loaded", value: 1)
        DiagnosticsStore.shared.recordLatency("llm_local_\(tier.rawValue)_model_load_ms", ms: elapsed)

        logger.info("Model loaded: tier=\(tier.rawValue) \(spec.localDirectoryName) in \(String(format: "%.0f", elapsed))ms")

        return loaded
    }

    // MARK: - Spec Resolution

    /// Look up the model spec for a tier from the registry.
    private static func spec(for tier: LocalModelTier) -> LocalModelSpec {
        switch tier {
        case .fast: return LocalModelRegistry.fastDefault
        case .deep: return LocalModelRegistry.deepDefault
        case .vision: return LocalModelRegistry.visionDefault
        case .embed: return LocalModelRegistry.embedDefault
        case .grounding: return LocalModelRegistry.groundingDefault
        }
    }

    // MARK: - Idle Timer

    /// Reset the idle timer for a specific tier. Called on every `ensureLoaded(tier:)`.
    private func resetIdleTimer(for tier: LocalModelTier) {
        idleTimerTasks[tier]?.cancel()

        idleTimerTasks[tier] = Task { [weak self, idleTimeout] in
            do {
                try await Task.sleep(nanoseconds: UInt64(idleTimeout * 1_000_000_000))
            } catch {
                return // Cancelled — new timer was started
            }

            guard let self else { return }
            // Check if we're still idle (no new ensureLoaded(tier:) since timer started)
            let lastUsedDate = await self.lastUsed[tier] ?? .distantPast
            let elapsed = Date().timeIntervalSince(lastUsedDate)
            if elapsed >= idleTimeout {
                await self.unload(tier: tier)
                logger.info("\(tier.rawValue) tier unloaded after \(Int(idleTimeout))s idle timeout")
            }
        }
    }

    // MARK: - Memory Pressure

    /// Create the memory pressure source. `nonisolated static` so it can be
    /// called from `init` without crossing actor isolation.
    ///
    /// The source's event handler captures the actor weakly and bridges to
    /// actor isolation via Task.
    ///
    /// On critical pressure, unloads all models — largest (deep) first.
    private nonisolated static func createMemoryPressureSource(
        for lifecycle: LocalModelLifecycle
    ) -> DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak lifecycle] in
            guard let lifecycle else { return }
            let event = source.data
            if event.contains(.critical) {
                logger.warning("Critical memory pressure — unloading all local models")
                Task {
                    // Unload largest first: deep (~18GB), vision (~5GB), grounding (~3GB), fast (~4.5GB)
                    await lifecycle.unload(tier: .deep)
                    await lifecycle.unload(tier: .vision)
                    await lifecycle.unload(tier: .grounding)
                    await lifecycle.unload(tier: .fast)
                }
            } else if event.contains(.warning) {
                logger.info("Memory pressure warning — models will unload on next critical event")
            }
        }

        source.resume()
        return source
    }
}
