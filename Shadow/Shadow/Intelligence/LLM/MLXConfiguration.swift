import Foundation
import MLX
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "MLXConfiguration")

/// Configures MLX GPU memory cache based on available system RAM.
///
/// MLX retains a Metal memory cache between operations to avoid repeated allocations.
/// Too high = memory pressure on the system (Shadow coexists with screen capture, OCR, etc.).
/// Too low = repeated allocations slow down inference.
///
/// Call `configure()` once at app launch, before any model loading.
enum MLXConfiguration {

    /// Configure the MLX GPU cache limit based on detected physical memory.
    ///
    /// This should be called once during app initialization. Subsequent calls
    /// are safe but unnecessary — MLX uses the most recent value.
    static func configure() {
        let totalRAMBytes = ProcessInfo.processInfo.physicalMemory
        let totalRAMGB = Int(totalRAMBytes / (1024 * 1024 * 1024))

        let cacheLimitMB: Int
        switch totalRAMGB {
        case ..<16:
            cacheLimitMB = 256
        case ..<32:
            cacheLimitMB = 512
        case ..<64:
            cacheLimitMB = 1024
        case ..<128:
            cacheLimitMB = 2048
        default:
            cacheLimitMB = 4096
        }

        Memory.cacheLimit = cacheLimitMB * 1024 * 1024
        logger.info("MLX GPU cache limit set to \(cacheLimitMB)MB (system RAM: \(totalRAMGB)GB)")
    }

    /// The detected system RAM in gigabytes.
    static var systemRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
}
