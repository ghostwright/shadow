import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "HardwareProfile")

// MARK: - Hardware Profile

/// Detected hardware capabilities for provisioning decisions.
///
/// All fields are populated at detection time and immutable.
/// The bandwidth lookup table covers Apple Silicon M1-M4 families.
struct HardwareProfile: Sendable {
    /// Chip marketing name, e.g. "Apple M4 Pro".
    let chipName: String
    /// Total physical RAM in whole GB.
    let totalRAMGB: Int
    /// GPU core count (performance cluster).
    let gpuCoreCount: Int
    /// Estimated unified memory bandwidth in GB/s.
    let memoryBandwidthGBs: Int
    /// Available disk space in whole GB.
    let availableDiskGB: Int
    /// macOS version string, e.g. "15.6.1".
    let macOSVersion: String

    // MARK: - Detection

    /// Detect the current hardware. Safe to call from any thread.
    static func detect() -> HardwareProfile {
        let chipName = detectChipName()
        let totalRAMGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let gpuCoreCount = detectGPUCoreCount()
        let bandwidth = lookupBandwidth(chipName: chipName)
        let availableDisk = detectAvailableDiskGB()
        let osVersion = formatOSVersion(ProcessInfo.processInfo.operatingSystemVersion)

        let profile = HardwareProfile(
            chipName: chipName,
            totalRAMGB: totalRAMGB,
            gpuCoreCount: gpuCoreCount,
            memoryBandwidthGBs: bandwidth,
            availableDiskGB: availableDisk,
            macOSVersion: osVersion
        )

        logger.info("Hardware: \(chipName), \(totalRAMGB)GB RAM, \(gpuCoreCount) GPU cores, \(bandwidth) GB/s BW, \(availableDisk)GB disk, macOS \(osVersion)")

        return profile
    }

    // MARK: - Chip Name Detection

    /// Read the CPU brand string via sysctl.
    /// Returns e.g. "Apple M4 Pro" on Apple Silicon, or "Unknown" on failure.
    static func detectChipName() -> String {
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }

        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        guard result == 0 else { return "Unknown" }

        return String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
    }

    // MARK: - GPU Core Count

    /// Detect GPU core count. On Apple Silicon, GPU cores are reported via
    /// IOKit's AGXAccelerator. Falls back to performance-level logical CPU count
    /// as a reasonable proxy, then to a hard-coded default.
    static func detectGPUCoreCount() -> Int {
        // Try IOKit: AGXAccelerator reports gpu-core-count
        if let gpuCores = readGPUCoreCountFromIOKit() {
            return gpuCores
        }

        // Fallback: performance-level logical CPU count (approximate proxy)
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0)
        if result == 0 && count > 0 {
            return Int(count)
        }

        // Last resort default
        return 8
    }

    /// Read GPU core count from IOKit's AGXAccelerator service.
    private static func readGPUCoreCountFromIOKit() -> Int? {
        var iterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("AGXAccelerator")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else {
            return nil
        }

        if let number = property as? NSNumber {
            return number.intValue
        }
        return nil
    }

    // MARK: - Memory Bandwidth Lookup

    /// Memory bandwidth lookup (GB/s) by chip family.
    /// Source: Apple spec pages for each chip generation.
    static let bandwidthTable: [String: Int] = [
        "M1": 68,
        "M1 Pro": 200,
        "M1 Max": 400,
        "M1 Ultra": 800,
        "M2": 100,
        "M2 Pro": 200,
        "M2 Max": 400,
        "M2 Ultra": 800,
        "M3": 100,
        "M3 Pro": 150,
        "M3 Max": 400,
        "M3 Ultra": 800,
        "M4": 120,
        "M4 Pro": 273,
        "M4 Max": 546,
        "M4 Ultra": 819,
    ]

    /// Extract the chip family from a brand string and look up bandwidth.
    /// "Apple M4 Pro" -> "M4 Pro" -> 273 GB/s.
    /// Returns a conservative default (100 GB/s) for unknown chips.
    static func lookupBandwidth(chipName: String) -> Int {
        let family = extractChipFamily(from: chipName)
        return bandwidthTable[family] ?? 100
    }

    /// Extract the chip family identifier from a brand string.
    /// "Apple M4 Pro" -> "M4 Pro", "Apple M1" -> "M1".
    static func extractChipFamily(from chipName: String) -> String {
        // Strip "Apple " prefix if present
        var name = chipName
        if name.hasPrefix("Apple ") {
            name = String(name.dropFirst(6))
        }
        // Trim whitespace
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Disk Space

    /// Available disk space in whole GB.
    static func detectAvailableDiskGB() -> Int {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: homeDir)
            if let freeBytes = attrs[.systemFreeSize] as? Int64 {
                return Int(freeBytes / (1024 * 1024 * 1024))
            }
        } catch {
            logger.warning("Failed to detect disk space: \(error, privacy: .public)")
        }
        return 0
    }

    // MARK: - macOS Version

    /// Format OperatingSystemVersion as "major.minor.patch" string.
    static func formatOSVersion(_ version: OperatingSystemVersion) -> String {
        if version.patchVersion > 0 {
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}
