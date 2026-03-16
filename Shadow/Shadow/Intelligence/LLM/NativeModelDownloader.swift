import Foundation
import Hub
import CryptoKit
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "NativeModelDownloader")

// MARK: - Download Progress

/// Observable download progress for SwiftUI binding.
///
/// All mutations happen on MainActor (via the actor's updateProgress helper).
/// All reads happen on MainActor (SwiftUI binding).
/// The @unchecked Sendable conformance is safe because the actor never reads
/// these properties directly -- it only writes via MainActor.run { }.
@Observable
final class ModelDownloadProgress: @unchecked Sendable {
    var phase: DownloadPhase = .idle
    var currentModelName: String = ""
    var byteFraction: Double = 0
    var bytesPerSecond: Double? = nil
    var completedModels: Int = 0
    var totalModels: Int = 0
    var errorMessage: String? = nil

    enum DownloadPhase: Sendable {
        case idle
        case downloading
        case verifying
        case completed
        case failed
    }
}

// MARK: - Native Model Download Manager

/// Pure Swift model download manager using HubApi from swift-transformers.
///
/// Replaces the Python-script-based downloader. Uses the same HubApi that
/// mlx-swift-lm uses internally, ensuring compatibility with the HuggingFace
/// Hub protocol (ETag caching, resumable downloads, LFS support, retry logic).
///
/// Key design choices:
/// - Downloads to ~/.shadow/models/.hub/ (HubApi-managed cache with metadata)
/// - Creates symlinks from ~/.shadow/models/llm/<name>/ ONLY after verification
/// - Existing real directories (from Python script) are kept if they pass verification
/// - Invalid real directories are quarantined and replaced with symlinks
/// - Cancellation propagates via Task.isCancelled; partial downloads are not promoted
/// - Single-flight: duplicate startDownloads calls are rejected while one is active
///
/// The Python script (scripts/provision-llm-models.py) remains in the repo
/// for build-from-source users who prefer CLI provisioning.
actor ModelDownloadManager {

    static let shared = ModelDownloadManager()

    /// Observable progress for SwiftUI binding.
    /// Created once, never replaced. Mutations go through updateProgress (MainActor).
    /// Access from non-MainActor contexts is limited to passing the reference;
    /// all property reads/writes happen on MainActor.
    let progress: ModelDownloadProgress

    init() {
        self.progress = ModelDownloadProgress()
    }

    /// Per-model download status for polling-based UI compatibility.
    private var statuses: [String: ModelDownloadStatus] = [:]

    /// Whether any downloads are currently active.
    private(set) var isDownloading: Bool = false

    /// Number of models successfully downloaded in this session.
    private(set) var completedCount: Int = 0

    /// Total number of models in the current plan.
    private(set) var totalCount: Int = 0

    /// The active download task. Stored so cancelAll() can cancel real work.
    private var downloadTask: Task<Void, Never>?

    /// Whether any model in the current plan failed.
    private var anyFailed: Bool = false

    // MARK: - Configuration

    /// Base directory for HubApi downloads and metadata.
    private static var hubCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shadow/models/.hub")
    }

    /// Inference-essential file patterns. Matches scripts/provision-llm-models.py
    /// INFERENCE_PATTERNS exactly.
    private static let inferencePatterns = [
        "*.safetensors",
        "*.json",
        "merges.txt",
        "vocab.txt",
        "vocab.json",
        "tokenizer.model",
    ]

    // MARK: - Public API

    /// Start downloading all models in the provisioning plan.
    ///
    /// Single-flight: if a download is already in progress, this returns immediately.
    /// Downloads sequentially (fast first, then deep) to minimize disk thrash.
    func startDownloads(plan: ProvisioningPlan) async {
        // Single-flight guard
        guard !isDownloading else {
            logger.info("Download already in progress, skipping duplicate request")
            return
        }

        let needed = plan.models.filter { !ModelVerifier.isVerified($0) }
        guard !needed.isEmpty else {
            logger.info("All planned models already downloaded and verified")
            DiagnosticsStore.shared.setGauge("provisioning_download_active", value: 0)
            return
        }

        isDownloading = true
        totalCount = needed.count
        completedCount = 0
        anyFailed = false
        statuses.removeAll()

        DiagnosticsStore.shared.setGauge("provisioning_download_active", value: 1)

        // Assign the task BEFORE the first await so cancelAll() can cancel it
        // even if called during the progress update below.
        downloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.executeDownloads(needed)
        }

        await updateProgress { p in
            p.phase = .downloading
            p.totalModels = needed.count
            p.completedModels = 0
            p.errorMessage = nil
        }
    }

    /// Cancel all in-progress downloads and wait for the worker to drain.
    ///
    /// Keeps isDownloading true until the worker task actually exits,
    /// preventing a restart from passing the single-flight guard while
    /// the cancelled worker is still unwinding.
    func cancelAll() async {
        guard let task = downloadTask else { return }
        task.cancel()
        // Wait for the worker to actually finish before clearing state.
        // The worker sets isDownloading = false in its cleanup path.
        await task.value
        downloadTask = nil
        await updateProgress { p in p.phase = .idle }
        logger.info("Model downloads cancelled")
    }

    /// Current download status for a specific model.
    func status(for spec: LocalModelSpec) -> ModelDownloadStatus {
        // Use the tracked status, not isDownloaded, to avoid promoting partial downloads
        if let tracked = statuses[spec.localDirectoryName] {
            return tracked
        }
        // Fall back to verified check for models not in the current plan
        if ModelVerifier.isVerified(spec) { return .completed }
        return .pending
    }

    /// Overall progress as a fraction (0.0 - 1.0).
    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    // MARK: - Download Execution

    /// Execute sequential downloads for all needed models.
    private func executeDownloads(_ specs: [LocalModelSpec]) async {
        for spec in specs {
            guard !Task.isCancelled else { break }

            statuses[spec.localDirectoryName] = .downloading

            await updateProgress { p in
                p.currentModelName = spec.localDirectoryName
                p.byteFraction = 0
                p.bytesPerSecond = nil
                p.phase = .downloading
            }

            logger.info("Downloading model: \(spec.localDirectoryName)")

            let success = await downloadModel(spec)

            if success {
                statuses[spec.localDirectoryName] = .completed
                completedCount += 1
                DiagnosticsStore.shared.increment("provisioning_download_complete_total")
                logger.info("Model download complete: \(spec.localDirectoryName)")
                await updateProgress { p in p.completedModels += 1 }
            } else if !Task.isCancelled {
                // Preserve the specific failure reason set by downloadModel.
                // Only set generic failure if downloadModel didn't set a specific one.
                let current = statuses[spec.localDirectoryName]
                switch current {
                case .failed: break // Already has a specific reason
                default: statuses[spec.localDirectoryName] = .failed("Download failed")
                }
                anyFailed = true
                DiagnosticsStore.shared.increment("provisioning_download_fail_total")
                logger.error("Model download failed: \(spec.localDirectoryName, privacy: .public)")
            }
        }

        isDownloading = false
        downloadTask = nil
        DiagnosticsStore.shared.setGauge("provisioning_download_active", value: 0)

        if Task.isCancelled {
            await updateProgress { p in p.phase = .idle }
            logger.info("Model downloads cancelled")
        } else if anyFailed {
            await updateProgress { p in p.phase = .failed }
            logger.info("Model provisioning finished with failures: \(self.completedCount)/\(self.totalCount)")
        } else {
            await updateProgress { p in p.phase = .completed }
            logger.info("Model provisioning complete: \(self.completedCount)/\(self.totalCount)")
        }
    }

    // MARK: - Single Model Download

    /// Download, verify, and install a single model.
    ///
    /// Flow: preflight → download → cancel check → verify → symlink
    /// Symlink is ONLY created after verification passes.
    private func downloadModel(_ spec: LocalModelSpec) async -> Bool {
        // Preflight: disk space
        let diskGB = HardwareProfile.detectAvailableDiskGB()
        let neededGB = spec.estimatedMemoryGB * 1.5
        if Double(diskGB) < neededGB {
            let msg = "Not enough disk space. Available: \(diskGB) GB, need ~\(Int(neededGB)) GB."
            logger.warning("\(msg) for \(spec.localDirectoryName)")
            statuses[spec.localDirectoryName] = .failed("Insufficient disk space")
            await updateProgress { p in p.errorMessage = msg }
            return false
        }

        let hub = HubApi(downloadBase: Self.hubCacheURL)
        let repo = Hub.Repo(id: spec.huggingFaceID)

        logger.info("Downloading \(spec.huggingFaceID) revision=\(spec.revision) (~\(spec.estimatedMemoryGB) GB)")

        // Track last progress update time for throttling
        let throttleState = ProgressThrottle()

        do {
            let downloadedURL = try await hub.snapshot(
                from: repo,
                revision: spec.revision,
                matching: Self.inferencePatterns
            ) { [weak self] hubProgress in
                guard let self else { return }
                // Throttle: max 2 updates per second
                guard throttleState.shouldUpdate() else { return }
                let fraction = hubProgress.fractionCompleted
                let speed = hubProgress.userInfo[.throughputKey] as? Double
                Task {
                    await self.updateProgress { p in
                        p.byteFraction = fraction
                        p.bytesPerSecond = speed
                    }
                }
            }

            // Cancel check AFTER download completes.
            // HubApi.snapshot() returns normally on cancellation instead of throwing.
            // Do NOT create symlinks or report success for cancelled downloads.
            guard !Task.isCancelled else {
                logger.info("Download cancelled for \(spec.localDirectoryName), not installing")
                return false
            }

            // Verify the downloaded content BEFORE creating any symlinks
            await updateProgress { p in p.phase = .verifying }

            let verification = ModelVerifier.verify(at: downloadedURL, spec: spec)
            guard verification.ok else {
                let msg = "Verification failed: \(verification.message)"
                logger.error("\(msg) for \(spec.localDirectoryName)")
                statuses[spec.localDirectoryName] = .failed(msg)
                await updateProgress { p in p.errorMessage = msg }
                // Invalidate HubApi's metadata cache so a retry can force refetch.
                // Without this, HubApi short-circuits on commit hash match and
                // returns corrupted files forever.
                // We delete only the .cache/huggingface/download/ metadata, not the
                // model files themselves, so resume can still work for partial downloads.
                Self.invalidateHubMetadata(at: downloadedURL)
                return false
            }

            // Verification passed. Now install: create symlink from Shadow's expected path
            // to the verified HubApi download location.
            let shadowPath = LocalModelRegistry.modelPath(for: spec)
            try installModel(from: downloadedURL, to: shadowPath, spec: spec)

            await updateProgress { p in p.phase = .downloading }
            return true

        } catch {
            if !Task.isCancelled {
                let msg = error.localizedDescription
                logger.error("Download failed for \(spec.localDirectoryName): \(msg, privacy: .public)")
                statuses[spec.localDirectoryName] = .failed(msg)
                await updateProgress { p in p.errorMessage = "Download failed: \(msg)" }
            }
            return false
        }
    }

    // MARK: - Model Installation

    /// Install a verified download at Shadow's expected model path.
    ///
    /// Handles:
    /// - No existing path: create symlink
    /// - Existing symlink: update if target changed
    /// - Existing valid real directory (Python-provisioned): keep it
    /// - Existing INVALID real directory: quarantine and replace with symlink
    private func installModel(from hubPath: URL, to shadowPath: URL, spec: LocalModelSpec) throws {
        let fm = FileManager.default

        // Ensure parent directory exists
        try fm.createDirectory(
            at: shadowPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Check what currently exists at the shadow path.
        // Use lstat-level check (resourceValues) to detect dangling symlinks,
        // which fileExists(atPath:) misses because it follows symlinks.
        let resourceValues: URLResourceValues
        do {
            resourceValues = try shadowPath.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        } catch {
            // Nothing exists at all (no entry, not even a dangling symlink): create symlink
            try fm.createSymbolicLink(at: shadowPath, withDestinationURL: hubPath)
            logger.info("Installed symlink: \(spec.localDirectoryName) -> \(hubPath.path)")
            return
        }

        // Check if it's a symlink (valid or dangling).
        if resourceValues.isSymbolicLink == true {
            // Check if it points to the right place (and target exists).
            let resolved = shadowPath.resolvingSymlinksInPath()
            let targetExists = fm.fileExists(atPath: resolved.path)
            if targetExists && resolved == hubPath.resolvingSymlinksInPath() {
                return // Already correct and target exists
            }
            // Dangling symlink or wrong target. Remove and recreate.
            try fm.removeItem(at: shadowPath)
            try fm.createSymbolicLink(at: shadowPath, withDestinationURL: hubPath)
            if !targetExists {
                logger.info("Repaired dangling symlink: \(spec.localDirectoryName) -> \(hubPath.path)")
            } else {
                logger.info("Updated symlink: \(spec.localDirectoryName) -> \(hubPath.path)")
            }
            return
        }

        // It's a real directory (from Python script or manual copy).
        // Verify it. If valid, keep it. If invalid, quarantine and replace.
        let existing = ModelVerifier.verify(at: shadowPath, spec: spec)
        if existing.ok {
            logger.info("Existing valid directory at \(spec.localDirectoryName), keeping it")
            return
        }

        // Invalid real directory. Quarantine it.
        let quarantineName = ".\(spec.localDirectoryName).quarantine.\(Int(Date().timeIntervalSince1970))"
        let quarantinePath = shadowPath.deletingLastPathComponent().appendingPathComponent(quarantineName)
        try fm.moveItem(at: shadowPath, to: quarantinePath)
        logger.warning("Quarantined invalid directory: \(spec.localDirectoryName) -> \(quarantineName)")

        // Now install the symlink
        try fm.createSymbolicLink(at: shadowPath, withDestinationURL: hubPath)
        logger.info("Installed symlink after quarantine: \(spec.localDirectoryName) -> \(hubPath.path)")
    }

    // MARK: - Hub Cache Invalidation

    /// Invalidate HubApi's metadata cache for a repo so retries refetch files.
    ///
    /// HubApi short-circuits downloads when local metadata (commit hash) matches
    /// the remote. If a completed download fails verification (corrupted file,
    /// model update), we must clear the metadata so HubApi re-checks ETags
    /// and re-downloads as needed on the next attempt.
    ///
    /// Only deletes .cache/ metadata, not the actual model files.
    private static func invalidateHubMetadata(at repoDirectory: URL) {
        let cacheDir = repoDirectory.appendingPathComponent(".cache")
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return }
        do {
            try FileManager.default.removeItem(at: cacheDir)
            logger.info("Invalidated Hub metadata cache at \(repoDirectory.lastPathComponent)")
        } catch {
            logger.warning("Failed to invalidate Hub cache: \(error, privacy: .public)")
        }
    }

    // MARK: - Progress Helpers

    /// Send a progress update to MainActor. All ModelDownloadProgress mutations
    /// go through this method to ensure MainActor isolation.
    private func updateProgress(_ update: @escaping @MainActor @Sendable (ModelDownloadProgress) -> Void) async {
        let p = progress
        await MainActor.run { update(p) }
    }
}

// MARK: - Progress Throttle

/// Simple time-based throttle for progress callbacks.
/// Prevents spawning thousands of Task objects during large downloads.
/// Thread-safe via os_unfair_lock since the callback may fire from
/// URLSession's delegate queue.
private final class ProgressThrottle: @unchecked Sendable {
    private var lastUpdate: Date = .distantPast
    private let interval: TimeInterval = 0.5
    private var lock = os_unfair_lock()

    func shouldUpdate() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= interval else { return false }
        lastUpdate = now
        return true
    }
}

// MARK: - Model Verifier

/// Verification of downloaded model directories.
///
/// Matches the Python script's verify_model() function:
/// 1. Required files exist (config.json, tokenizer.json, etc.)
/// 2. At least one .safetensors weight file present
/// 3. config.json SHA256 matches pinned value (when pinned)
/// 4. Weight fingerprint matches pinned value (when pinned)
enum ModelVerifier {

    struct Result {
        let ok: Bool
        let message: String
    }

    /// Quick check: is a model present and structurally valid?
    /// Used by the download filter to skip already-verified models.
    static func isVerified(_ spec: LocalModelSpec) -> Bool {
        let path = LocalModelRegistry.modelPath(for: spec)
        let resolved = path.resolvingSymlinksInPath()
        return verify(at: resolved, spec: spec).ok
    }

    /// Full verification matching the Python script's verify_model().
    static func verify(at directory: URL, spec: LocalModelSpec) -> Result {
        let fm = FileManager.default
        let resolved = directory.resolvingSymlinksInPath()

        guard fm.fileExists(atPath: resolved.path) else {
            return Result(ok: false, message: "Directory does not exist")
        }

        // 1. Required files
        for file in spec.requiredFiles {
            if !fm.fileExists(atPath: resolved.appendingPathComponent(file).path) {
                return Result(ok: false, message: "Missing required file: \(file)")
            }
        }

        // 2. Weight files
        let contents = (try? fm.contentsOfDirectory(atPath: resolved.path)) ?? []
        let hasSafetensors = contents.contains { $0.hasSuffix(".safetensors") }
        guard hasSafetensors else {
            return Result(ok: false, message: "No .safetensors weight files found")
        }

        // 3. config.json SHA256 (when pinned)
        if let expectedConfigHash = spec.configSHA256 {
            let configPath = resolved.appendingPathComponent("config.json")
            guard let actualHash = sha256File(at: configPath) else {
                return Result(ok: false, message: "Cannot read config.json for hash check")
            }
            guard actualHash == expectedConfigHash else {
                return Result(ok: false, message: "config.json hash mismatch: expected \(expectedConfigHash.prefix(16))..., got \(actualHash.prefix(16))...")
            }
        }

        // 4. Weight fingerprint (when pinned)
        if let expectedFingerprint = spec.weightFingerprint {
            guard let actualFingerprint = weightFingerprint(at: resolved) else {
                return Result(ok: false, message: "Cannot compute weight fingerprint")
            }
            guard actualFingerprint == expectedFingerprint else {
                return Result(ok: false, message: "Weight fingerprint mismatch: expected \(expectedFingerprint.prefix(16))..., got \(actualFingerprint.prefix(16))...")
            }
        }

        return Result(ok: true, message: "Verified")
    }

    /// Compute weight fingerprint (SHA256 composite hash).
    ///
    /// Matches scripts/provision-llm-models.py weight_fingerprint() exactly:
    /// SHA256 over (filename + "\0" + file_sha256 + "\0") for all
    /// inference-essential files, sorted by filename, deduplicated.
    static func weightFingerprint(at directory: URL) -> String? {
        let resolved = directory.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: resolved.path) else {
            return nil
        }

        let inferenceExtensions: Set<String> = ["safetensors", "json"]
        let inferenceNames: Set<String> = [
            "merges.txt", "vocab.txt", "vocab.json", "tokenizer.model",
        ]

        // Use Set for deduplication (vocab.json matches both .json extension and name)
        var fileSet = Set<String>()
        for name in contents {
            let ext = (name as NSString).pathExtension
            if inferenceExtensions.contains(ext) || inferenceNames.contains(name) {
                fileSet.insert(name)
            }
        }

        guard !fileSet.isEmpty else { return nil }
        let files = fileSet.sorted()

        var hasher = SHA256()
        for name in files {
            let filePath = resolved.appendingPathComponent(name)
            guard let fileHash = sha256File(at: filePath) else {
                // Unreadable inference file is a hard failure, matching Python's behavior
                return nil
            }
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(fileHash.utf8))
            hasher.update(data: Data([0]))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA256 hash of a file, reading in 64KB chunks.
    /// Matches scripts/provision-llm-models.py sha256_file().
    static func sha256File(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
