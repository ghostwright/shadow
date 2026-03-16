import XCTest
@testable import Shadow

final class HardwareProfileTests: XCTestCase {

    // MARK: - detect() sanity checks

    func testDetect_returnsNonEmptyChipName() {
        let profile = HardwareProfile.detect()
        XCTAssertFalse(profile.chipName.isEmpty, "Chip name should not be empty")
        XCTAssertNotEqual(profile.chipName, "Unknown", "Should detect a chip name on Apple Silicon")
    }

    func testDetect_returnsPositiveRAM() {
        let profile = HardwareProfile.detect()
        XCTAssertGreaterThan(profile.totalRAMGB, 0, "System should have at least 1 GB RAM")
    }

    func testDetect_returnsPositiveGPUCores() {
        let profile = HardwareProfile.detect()
        XCTAssertGreaterThan(profile.gpuCoreCount, 0, "Should detect at least 1 GPU core")
    }

    func testDetect_returnsPositiveBandwidth() {
        let profile = HardwareProfile.detect()
        XCTAssertGreaterThan(profile.memoryBandwidthGBs, 0, "Bandwidth should be positive")
    }

    func testDetect_returnsPositiveDiskSpace() {
        let profile = HardwareProfile.detect()
        XCTAssertGreaterThan(profile.availableDiskGB, 0, "Should have some free disk space")
    }

    func testDetect_returnsNonEmptyMacOSVersion() {
        let profile = HardwareProfile.detect()
        XCTAssertFalse(profile.macOSVersion.isEmpty, "macOS version should not be empty")
        XCTAssertTrue(profile.macOSVersion.contains("."), "Version should contain at least one dot")
    }

    // MARK: - Chip family extraction

    func testExtractChipFamily_appleM4Pro() {
        let family = HardwareProfile.extractChipFamily(from: "Apple M4 Pro")
        XCTAssertEqual(family, "M4 Pro")
    }

    func testExtractChipFamily_appleM1() {
        let family = HardwareProfile.extractChipFamily(from: "Apple M1")
        XCTAssertEqual(family, "M1")
    }

    func testExtractChipFamily_appleM3Ultra() {
        let family = HardwareProfile.extractChipFamily(from: "Apple M3 Ultra")
        XCTAssertEqual(family, "M3 Ultra")
    }

    func testExtractChipFamily_noApplePrefix() {
        let family = HardwareProfile.extractChipFamily(from: "M2 Max")
        XCTAssertEqual(family, "M2 Max")
    }

    // MARK: - Bandwidth lookup

    func testLookupBandwidth_knownChips() {
        XCTAssertEqual(HardwareProfile.lookupBandwidth(chipName: "Apple M1"), 68)
        XCTAssertEqual(HardwareProfile.lookupBandwidth(chipName: "Apple M1 Pro"), 200)
        XCTAssertEqual(HardwareProfile.lookupBandwidth(chipName: "Apple M1 Max"), 400)
        XCTAssertEqual(HardwareProfile.lookupBandwidth(chipName: "Apple M1 Ultra"), 800)
        XCTAssertEqual(HardwareProfile.lookupBandwidth(chipName: "Apple M2"), 100)
        XCTAssertEqual(HardwareProfile.lookupBandwidth(chipName: "Apple M3 Pro"), 150)
        XCTAssertEqual(HardwareProfile.lookupBandwidth(chipName: "Apple M4 Pro"), 273)
        XCTAssertEqual(HardwareProfile.lookupBandwidth(chipName: "Apple M4 Max"), 546)
        XCTAssertEqual(HardwareProfile.lookupBandwidth(chipName: "Apple M4 Ultra"), 819)
    }

    func testLookupBandwidth_unknownChip_returnsDefault() {
        let bandwidth = HardwareProfile.lookupBandwidth(chipName: "Apple M99 Super")
        XCTAssertEqual(bandwidth, 100, "Unknown chips should return 100 GB/s default")
    }

    func testLookupBandwidth_emptyString_returnsDefault() {
        let bandwidth = HardwareProfile.lookupBandwidth(chipName: "")
        XCTAssertEqual(bandwidth, 100, "Empty chip name should return default")
    }

    // MARK: - Bandwidth table completeness

    func testBandwidthTable_coversAllMGenerations() {
        let table = HardwareProfile.bandwidthTable
        // M1 family
        XCTAssertNotNil(table["M1"])
        XCTAssertNotNil(table["M1 Pro"])
        XCTAssertNotNil(table["M1 Max"])
        XCTAssertNotNil(table["M1 Ultra"])
        // M2 family
        XCTAssertNotNil(table["M2"])
        XCTAssertNotNil(table["M2 Pro"])
        XCTAssertNotNil(table["M2 Max"])
        XCTAssertNotNil(table["M2 Ultra"])
        // M3 family
        XCTAssertNotNil(table["M3"])
        XCTAssertNotNil(table["M3 Pro"])
        XCTAssertNotNil(table["M3 Max"])
        XCTAssertNotNil(table["M3 Ultra"])
        // M4 family
        XCTAssertNotNil(table["M4"])
        XCTAssertNotNil(table["M4 Pro"])
        XCTAssertNotNil(table["M4 Max"])
        XCTAssertNotNil(table["M4 Ultra"])

        XCTAssertEqual(table.count, 16, "Should have exactly 16 entries (4 generations x 4 variants)")
    }

    // MARK: - macOS version formatting

    func testFormatOSVersion_withPatch() {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)
        XCTAssertEqual(HardwareProfile.formatOSVersion(version), "15.6.1")
    }

    func testFormatOSVersion_withoutPatch() {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(HardwareProfile.formatOSVersion(version), "15.0")
    }

    // MARK: - Disk space detection

    func testDetectAvailableDiskGB_returnsPositive() {
        let disk = HardwareProfile.detectAvailableDiskGB()
        XCTAssertGreaterThan(disk, 0, "Should detect available disk space")
    }

    // MARK: - Chip name detection

    func testDetectChipName_returnsNonEmpty() {
        let name = HardwareProfile.detectChipName()
        XCTAssertFalse(name.isEmpty)
    }
}
