import XCTest
@testable import Shadow

final class ModelProvisionerTests: XCTestCase {

    // MARK: - Plan for 16 GB machine

    func testPlan_16GB_includesFastOnly() {
        let hardware = HardwareProfile(
            chipName: "Apple M2",
            totalRAMGB: 16,
            gpuCoreCount: 8,
            memoryBandwidthGBs: 100,
            availableDiskGB: 200,
            macOSVersion: "15.0"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertEqual(plan.models.count, 1, "16 GB should include only fast tier")
        XCTAssertEqual(plan.models.first?.tier, .fast)
        XCTAssertTrue(plan.warnings.isEmpty, "No warnings expected for 16 GB with enough disk")
    }

    func testPlan_16GB_excludesDeep() {
        let hardware = HardwareProfile(
            chipName: "Apple M2",
            totalRAMGB: 16,
            gpuCoreCount: 8,
            memoryBandwidthGBs: 100,
            availableDiskGB: 200,
            macOSVersion: "15.0"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        let hasDeep = plan.models.contains { $0.tier == .deep }
        XCTAssertFalse(hasDeep, "16 GB machine should not include deep tier")
    }

    // MARK: - Plan for 48 GB machine

    func testPlan_48GB_includesFastAndDeep() {
        let hardware = HardwareProfile(
            chipName: "Apple M4 Pro",
            totalRAMGB: 48,
            gpuCoreCount: 20,
            memoryBandwidthGBs: 273,
            availableDiskGB: 500,
            macOSVersion: "15.6"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertEqual(plan.models.count, 2, "48 GB should include fast and deep")
        let tiers = plan.models.map(\.tier)
        XCTAssertTrue(tiers.contains(.fast))
        XCTAssertTrue(tiers.contains(.deep))
    }

    func testPlan_48GB_ordersFastBeforeDeep() {
        let hardware = HardwareProfile(
            chipName: "Apple M4 Pro",
            totalRAMGB: 48,
            gpuCoreCount: 20,
            memoryBandwidthGBs: 273,
            availableDiskGB: 500,
            macOSVersion: "15.6"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertEqual(plan.models.count, 2)
        XCTAssertEqual(plan.models[0].tier, .fast, "Fast tier should be first (smaller, downloads faster)")
        XCTAssertEqual(plan.models[1].tier, .deep, "Deep tier should be second")
    }

    // MARK: - Plan for 8 GB machine (cloud only)

    func testPlan_8GB_returnsEmpty() {
        let hardware = HardwareProfile(
            chipName: "Apple M1",
            totalRAMGB: 8,
            gpuCoreCount: 8,
            memoryBandwidthGBs: 68,
            availableDiskGB: 100,
            macOSVersion: "15.0"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertTrue(plan.models.isEmpty, "8 GB should be cloud-only")
    }

    func testPlan_8GB_hasInsufficientRAMWarning() {
        let hardware = HardwareProfile(
            chipName: "Apple M1",
            totalRAMGB: 8,
            gpuCoreCount: 8,
            memoryBandwidthGBs: 68,
            availableDiskGB: 100,
            macOSVersion: "15.0"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertFalse(plan.warnings.isEmpty, "Should warn about insufficient RAM")
        XCTAssertTrue(
            plan.warnings.first?.contains("Insufficient RAM") == true,
            "Warning should mention insufficient RAM"
        )
    }

    // MARK: - Disk space warnings

    func testPlan_lowDisk_hasWarning() {
        let hardware = HardwareProfile(
            chipName: "Apple M2",
            totalRAMGB: 16,
            gpuCoreCount: 8,
            memoryBandwidthGBs: 100,
            availableDiskGB: 3,    // 3 GB free, fast model needs ~4.5 * 1.5 = ~6.75 GB
            macOSVersion: "15.0"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        let diskWarning = plan.warnings.first { $0.contains("disk space") || $0.contains("Low disk") }
        XCTAssertNotNil(diskWarning, "Should warn about low disk space")
    }

    func testPlan_sufficientDisk_noWarning() {
        let hardware = HardwareProfile(
            chipName: "Apple M2",
            totalRAMGB: 16,
            gpuCoreCount: 8,
            memoryBandwidthGBs: 100,
            availableDiskGB: 200,
            macOSVersion: "15.0"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertTrue(plan.warnings.isEmpty, "Should have no warnings with sufficient resources")
    }

    // MARK: - Disk and memory estimates

    func testPlan_estimatedDiskUsage_isPositive() {
        let hardware = HardwareProfile(
            chipName: "Apple M4 Pro",
            totalRAMGB: 48,
            gpuCoreCount: 20,
            memoryBandwidthGBs: 273,
            availableDiskGB: 500,
            macOSVersion: "15.6"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertGreaterThan(plan.estimatedDiskUsageGB, 0, "Should have a disk usage estimate")
    }

    func testPlan_estimatedPeakMemory_isPositive() {
        let hardware = HardwareProfile(
            chipName: "Apple M4 Pro",
            totalRAMGB: 48,
            gpuCoreCount: 20,
            memoryBandwidthGBs: 273,
            availableDiskGB: 500,
            macOSVersion: "15.6"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertGreaterThan(plan.estimatedPeakMemoryGB, 0, "Should have a peak memory estimate")
    }

    func testPlan_emptyModels_zeroPeakMemory() {
        let hardware = HardwareProfile(
            chipName: "Apple M1",
            totalRAMGB: 8,
            gpuCoreCount: 8,
            memoryBandwidthGBs: 68,
            availableDiskGB: 100,
            macOSVersion: "15.0"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertEqual(plan.estimatedPeakMemoryGB, 0, "No models means zero peak memory")
    }

    // MARK: - Edge cases

    func testPlan_24GB_includesFastOnly() {
        let hardware = HardwareProfile(
            chipName: "Apple M3",
            totalRAMGB: 24,
            gpuCoreCount: 10,
            memoryBandwidthGBs: 100,
            availableDiskGB: 200,
            macOSVersion: "15.0"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertEqual(plan.models.count, 1)
        XCTAssertEqual(plan.models.first?.tier, .fast)
    }

    func testPlan_128GB_inclusFastAndDeep() {
        let hardware = HardwareProfile(
            chipName: "Apple M4 Ultra",
            totalRAMGB: 128,
            gpuCoreCount: 80,
            memoryBandwidthGBs: 819,
            availableDiskGB: 1000,
            macOSVersion: "15.0"
        )

        let plan = ModelProvisioner.plan(for: hardware)

        XCTAssertEqual(plan.models.count, 2)
        XCTAssertTrue(plan.models.contains { $0.tier == .fast })
        XCTAssertTrue(plan.models.contains { $0.tier == .deep })
    }

    // MARK: - Download status

    func testModelDownloadStatus_defaultIsPending() async {
        let spec = LocalModelSpec(
            tier: .fast,
            huggingFaceID: "test/nonexistent",
            localDirectoryName: "nonexistent-test-model-xyz",
            estimatedMemoryGB: 1.0,
            minimumSystemRAMGB: 8,
            contextLength: 4096,
            supportsToolCalling: false,
            revision: "main",
            requiredFiles: ["config.json"],
            configSHA256: nil,
            weightFingerprint: nil
        )

        let status = await ModelDownloadManager.shared.status(for: spec)
        switch status {
        case .pending: break  // expected
        case .completed: break  // also acceptable if somehow downloaded
        default:
            XCTFail("Expected pending status for undownloaded model, got \(status)")
        }
    }

    func testModelDownloadManager_initialState() async {
        let manager = ModelDownloadManager.shared
        let downloading = await manager.isDownloading
        XCTAssertFalse(downloading, "Should not be downloading on initial state check")

        let progress = await manager.overallProgress
        // Progress may be 0 or reflect a previous run — just verify it's valid
        XCTAssertGreaterThanOrEqual(progress, 0)
        XCTAssertLessThanOrEqual(progress, 1.0)
    }
}
