import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ModelProvisioner")

// MARK: - Provisioning Plan

/// Describes which models to download and in what order.
struct ProvisioningPlan: Sendable {
    /// Models to download, ordered by priority (fast first, then deep).
    let models: [LocalModelSpec]
    /// Total estimated download size in GB.
    let estimatedDiskUsageGB: Double
    /// Peak memory usage if the largest model is loaded.
    let estimatedPeakMemoryGB: Double
    /// User-facing warnings (e.g., insufficient RAM, low disk).
    let warnings: [String]
}

// MARK: - Model Provisioner

/// Generates a provisioning plan based on detected hardware.
///
/// The plan determines which local LLM models should be downloaded.
/// Models are ordered by priority: fast tier (7B) first since it's smaller
/// and gets the system working faster, then deep tier (32B) if hardware supports it.
enum ModelProvisioner {

    /// Generate a provisioning plan for the given hardware profile.
    ///
    /// Logic:
    /// - RAM >= 16 GB: include fast tier (7B, ~4.5 GB)
    /// - RAM >= 48 GB: include deep tier (32B, ~20 GB)
    /// - RAM < 16 GB: cloud-only mode, no local models
    /// - Disk check: need 1.5x total download size as safety margin
    static func plan(for hardware: HardwareProfile) -> ProvisioningPlan {
        var models: [LocalModelSpec] = []
        var warnings: [String] = []

        let fast = LocalModelRegistry.fastDefault
        let deep = LocalModelRegistry.deepDefault

        // Fast tier: 7B model for quick inference
        if hardware.totalRAMGB >= fast.minimumSystemRAMGB {
            models.append(fast)
        } else {
            warnings.append(
                "Insufficient RAM (\(hardware.totalRAMGB) GB) for local LLM inference. "
                + "Requires \(fast.minimumSystemRAMGB) GB minimum. Using cloud-only mode."
            )
        }

        // Deep tier: 32B model for higher-quality reasoning
        if hardware.totalRAMGB >= deep.minimumSystemRAMGB {
            models.append(deep)
        }

        // Calculate disk requirements
        let totalDiskGB = models.reduce(0.0) { $0 + $1.estimatedMemoryGB * diskMultiplier(for: $1) }
        let requiredDiskGB = totalDiskGB * 1.5  // 1.5x safety margin

        if !models.isEmpty && Double(hardware.availableDiskGB) < requiredDiskGB {
            warnings.append(
                "Low disk space: \(hardware.availableDiskGB) GB available, "
                + "need ~\(Int(requiredDiskGB)) GB (\(Int(totalDiskGB)) GB models + safety margin). "
                + "Some models may not download."
            )
        }

        // Peak memory = largest model's estimated memory
        let peakMemory = models.map(\.estimatedMemoryGB).max() ?? 0

        let plan = ProvisioningPlan(
            models: models,
            estimatedDiskUsageGB: totalDiskGB,
            estimatedPeakMemoryGB: peakMemory,
            warnings: warnings
        )

        let diskStr = String(format: "%.1f", totalDiskGB)
        logger.info("Provisioning plan: \(models.count) models, ~\(diskStr) GB disk, \(warnings.count) warnings")

        return plan
    }

    /// Disk size multiplier per tier. The on-disk size is larger than the
    /// in-memory size due to tokenizer, config, and overhead files.
    /// Fast tier ~4.5 GB in-memory estimate maps to ~4.5 GB on disk.
    /// Deep tier ~18 GB in-memory estimate maps to ~20 GB on disk.
    private static func diskMultiplier(for spec: LocalModelSpec) -> Double {
        switch spec.tier {
        case .deep: return 1.11   // 18 GB memory -> ~20 GB disk
        default: return 1.0
        }
    }
}

// MARK: - Download Status

/// Status of a single model download.
enum ModelDownloadStatus: Sendable {
    case pending
    case downloading
    case completed
    case failed(String)
}

// ModelDownloadManager has been moved to NativeModelDownloader.swift.
// It now uses pure Swift (HubApi from swift-transformers) instead of
// invoking the Python provisioning script via Process.
//
// The Python script (scripts/provision-llm-models.py) remains in the repo
// for build-from-source users who prefer CLI provisioning.
