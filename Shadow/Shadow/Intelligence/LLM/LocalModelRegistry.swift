import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "LocalModelRegistry")

// MARK: - Model Tier

/// Classification of local model capabilities.
/// Determines which model is loaded for different task types.
enum LocalModelTier: String, Codable, CaseIterable, Sendable {
    /// 7B-class model: fast inference, good for summaries and simple tool calling.
    case fast
    /// 32B-class model: slower but higher quality reasoning and analysis.
    case deep
    /// Vision-language model: can process images alongside text.
    case vision
    /// Embedding model: produces vector representations for semantic search.
    case embed
    /// Grounding model: small VLM optimized for finding UI elements on screenshots.
    /// Used by the Mimicry system for AX-fallback element grounding.
    case grounding
}

// MARK: - Model Spec

/// Describes a specific local model that Shadow knows how to load.
///
/// This is a static catalog, not a dynamic discovery system. We control exactly
/// which models are supported and where they live on disk.
///
/// Verification fields (revision, requiredFiles, configSHA256, weightFingerprint)
/// mirror the Python script's MODELS dict for parity. When pinned values are set,
/// downloads are verified against them. When nil, only structural checks run.
struct LocalModelSpec: Sendable {
    /// The tier this model serves.
    let tier: LocalModelTier
    /// HuggingFace model identifier (e.g. "mlx-community/Qwen2.5-7B-Instruct-4bit").
    let huggingFaceID: String
    /// Directory name under `~/.shadow/models/llm/` (e.g. "Qwen2.5-7B-Instruct-4bit").
    let localDirectoryName: String
    /// Estimated GPU memory required in GB. Used for provisioning decisions.
    let estimatedMemoryGB: Double
    /// Minimum system RAM in GB. Model will not be offered below this threshold.
    let minimumSystemRAMGB: Int
    /// Maximum context length in tokens.
    let contextLength: Int
    /// Whether the model supports structured tool calling.
    let supportsToolCalling: Bool
    /// HuggingFace revision (git commit hash or "main"). Pinning to a commit
    /// ensures reproducible downloads. Matches Python script's "revision" field.
    let revision: String
    /// Files that must exist for the model to be considered valid.
    /// Matches Python script's "required_files" per model.
    let requiredFiles: [String]
    /// SHA256 of config.json when pinned. Nil means skip this check.
    /// Matches Python script's "config_sha256" field.
    let configSHA256: String?
    /// Composite SHA256 over all inference-essential files (sorted by name).
    /// Nil means skip this check. Matches Python script's "weight_fingerprint" field.
    let weightFingerprint: String?
}

// MARK: - Model Registry

/// Type-safe catalog of every model Shadow knows how to load.
///
/// Models are provisioned by either:
/// - NativeModelDownloader (Swift, via HubApi) for .app bundles and runtime downloads
/// - scripts/provision-llm-models.py (Python, via huggingface_hub) for CLI/build-from-source
///
/// Both paths store models at `~/.shadow/models/llm/<localDirectoryName>/`.
/// The Swift path downloads to `~/.shadow/models/.hub/` and creates symlinks.
/// The Python path writes directly. Both coexist safely.
enum LocalModelRegistry {

    // MARK: - Default Models

    // Pinned revision and hashes match scripts/provision-llm-models.py MODELS dict.
    // To update pins: run `python3 scripts/provision-llm-models.py --pin` after download.

    static let fastDefault = LocalModelSpec(
        tier: .fast,
        huggingFaceID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        localDirectoryName: "Qwen2.5-7B-Instruct-4bit",
        estimatedMemoryGB: 4.5,
        minimumSystemRAMGB: 16,
        contextLength: 32768,
        supportsToolCalling: true,
        revision: "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed",
        requiredFiles: ["config.json", "tokenizer.json"],
        configSHA256: "1661a349986919d13820d3981623776138d50783d13e247cdc5b075a22b62698",
        weightFingerprint: "a572fe6b4290ff41ea22e64cc6711fd01afcd11febdd42b903e4269a7ddc9d08"
    )

    static let deepDefault = LocalModelSpec(
        tier: .deep,
        huggingFaceID: "mlx-community/Qwen2.5-32B-Instruct-4bit",
        localDirectoryName: "Qwen2.5-32B-Instruct-4bit",
        estimatedMemoryGB: 20.0,
        minimumSystemRAMGB: 48,
        contextLength: 32768,
        supportsToolCalling: true,
        revision: "main",
        requiredFiles: ["config.json", "tokenizer.json"],
        configSHA256: nil,
        weightFingerprint: nil
    )

    static let visionDefault = LocalModelSpec(
        tier: .vision,
        huggingFaceID: "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
        localDirectoryName: "Qwen2.5-VL-7B-Instruct-4bit",
        estimatedMemoryGB: 5.0,
        minimumSystemRAMGB: 24,
        contextLength: 8192,
        supportsToolCalling: false,
        revision: "main",
        requiredFiles: ["config.json", "tokenizer.json", "preprocessor_config.json"],
        configSHA256: nil,
        weightFingerprint: nil
    )

    static let embedDefault = LocalModelSpec(
        tier: .embed,
        huggingFaceID: "nomic-ai/nomic-embed-text-v1.5",
        localDirectoryName: "nomic-embed-text-v1.5",
        estimatedMemoryGB: 0.3,
        minimumSystemRAMGB: 8,
        contextLength: 8192,
        supportsToolCalling: false,
        revision: "main",
        requiredFiles: ["config.json"],
        configSHA256: nil,
        weightFingerprint: nil
    )

    /// Grounding model: ShowUI-2B (8-bit MLX) for fast UI element grounding.
    /// Based on Qwen2-VL-2B, pre-trained on 256K GUI grounding examples.
    /// 75.1% zero-shot grounding accuracy. ~300-500ms per inference on M4 Pro.
    static let groundingDefault = LocalModelSpec(
        tier: .grounding,
        huggingFaceID: "mlx-community/ShowUI-2B-bf16-8bit",
        localDirectoryName: "ShowUI-2B-bf16-8bit",
        estimatedMemoryGB: 3.0,
        minimumSystemRAMGB: 16,
        contextLength: 4096,
        supportsToolCalling: false,
        revision: "main",
        requiredFiles: ["config.json", "tokenizer.json", "preprocessor_config.json"],
        configSHA256: "f89c882af51e7c14af9c9f9f4c278696d672c3cdc15c8f0eef5552e940145f23",
        weightFingerprint: "46555d91999af0ed3df67dbc92ad013f779851c8e4788f67288ca8d28a819372"
    )

    /// Draft model for speculative decoding. Paired with the fast (7B) verifier.
    /// Qwen2.5-1.5B shares the same tokenizer and vocabulary as the 7B verifier.
    /// At ~1 GB, co-provisioned alongside the 7B fast model.
    static let draftDefault = LocalModelSpec(
        tier: .fast,
        huggingFaceID: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        localDirectoryName: "Qwen2.5-1.5B-Instruct-4bit",
        estimatedMemoryGB: 1.0,
        minimumSystemRAMGB: 8,
        contextLength: 32768,
        supportsToolCalling: false,
        revision: "main",
        requiredFiles: ["config.json", "tokenizer.json"],
        configSHA256: nil,
        weightFingerprint: nil
    )

    /// All known model specs (excluding draft — draft is a speculative decoding assistant,
    /// not a standalone tier model).
    static let allSpecs: [LocalModelSpec] = [fastDefault, deepDefault, visionDefault, embedDefault, groundingDefault]

    // MARK: - Path Resolution

    /// Base directory for all local LLM models.
    static var modelsBaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shadow/models/llm")
    }

    /// Base directory for local embedding models.
    static var embeddingsBaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shadow/models/embeddings")
    }

    /// Resolve the on-disk directory for a model spec.
    /// LLM models live at `~/.shadow/models/llm/<localDirectoryName>/`.
    /// Embedding models live at `~/.shadow/models/embeddings/<localDirectoryName>/`.
    static func modelPath(for spec: LocalModelSpec) -> URL {
        let base = spec.tier == .embed ? embeddingsBaseURL : modelsBaseURL
        return base.appendingPathComponent(spec.localDirectoryName)
    }

    // MARK: - Download Check

    /// Check if a model is structurally present on disk.
    ///
    /// A model is considered "downloaded" if its directory exists (resolving
    /// symlinks), all required files are present, AND at least one .safetensors
    /// weight file exists. This is stronger than "any safetensors present" but
    /// cheaper than full SHA256 verification (no hashing).
    ///
    /// For full integrity verification (config hash + weight fingerprint),
    /// use ModelVerifier.isVerified() instead. That is used by the download
    /// manager to decide whether to re-download.
    static func isDownloaded(_ spec: LocalModelSpec) -> Bool {
        let path = modelPath(for: spec)
        let fm = FileManager.default
        let resolved = path.resolvingSymlinksInPath()

        guard fm.fileExists(atPath: resolved.path) else { return false }

        // Check all required files exist
        for file in spec.requiredFiles {
            if !fm.fileExists(atPath: resolved.appendingPathComponent(file).path) {
                return false
            }
        }

        // Check for weight files
        let contents = (try? fm.contentsOfDirectory(atPath: resolved.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Find the default model spec for a given tier, if downloaded.
    static func availableModel(for tier: LocalModelTier) -> LocalModelSpec? {
        let spec: LocalModelSpec?
        switch tier {
        case .fast: spec = fastDefault
        case .deep: spec = deepDefault
        case .vision: spec = visionDefault
        case .embed: spec = embedDefault
        case .grounding: spec = groundingDefault
        }

        guard let spec, isDownloaded(spec) else { return nil }

        // Check system RAM meets minimum requirement
        let systemRAMGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        guard systemRAMGB >= spec.minimumSystemRAMGB else {
            logger.warning(
                "Model \(spec.localDirectoryName) requires \(spec.minimumSystemRAMGB)GB RAM, system has \(systemRAMGB)GB"
            )
            return nil
        }

        return spec
    }
}
