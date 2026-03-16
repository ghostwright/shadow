import Cocoa
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "DiagnosticsExporter")

/// Exports a diagnostics bundle to the user's Desktop for debugging/review.
enum DiagnosticsExporter {

    /// Export a timestamped diagnostics bundle.
    static func export() {
        let snapshot = DiagnosticsStore.shared.snapshot()
        let dateStr = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        let bundleDir = desktop.appendingPathComponent("shadow-diagnostics-\(dateStr)")

        do {
            try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

            // 1. Metrics snapshot
            let metricsDict: [String: Any] = [
                "counters": snapshot.counters.mapValues { NSNumber(value: $0) },
                "gauges": snapshot.gauges,
                "high_water_marks": snapshot.highWaterMarks.mapValues { NSNumber(value: $0) },
                "latency_p50": snapshot.latencyP50,
                "latency_p95": snapshot.latencyP95,
            ]
            let metricsData = try JSONSerialization.data(
                withJSONObject: metricsDict, options: [.prettyPrinted, .sortedKeys]
            )
            try metricsData.write(to: bundleDir.appendingPathComponent("metrics_snapshot.json"))

            // 2. Recent warnings
            let warningsList = snapshot.warnings.map { w -> [String: Any] in
                [
                    "timestamp": ISO8601DateFormatter().string(from: w.timestamp),
                    "severity": w.severity.rawValue,
                    "subsystem": w.subsystem,
                    "code": w.code,
                    "message": w.message,
                    "context": w.context,
                ]
            }
            let warningsData = try JSONSerialization.data(
                withJSONObject: warningsList, options: [.prettyPrinted, .sortedKeys]
            )
            try warningsData.write(to: bundleDir.appendingPathComponent("warnings_recent.json"))

            // 3. Build info
            let buildInfo: [String: Any] = [
                "core_version": coreVersion(),
                "export_time": dateStr,
                "session_id": EventWriter.clock?.sessionId ?? "unknown",
            ]
            let buildData = try JSONSerialization.data(
                withJSONObject: buildInfo, options: [.prettyPrinted, .sortedKeys]
            )
            try buildData.write(to: bundleDir.appendingPathComponent("build_info.json"))

            // 4. Integrity report
            do {
                let report = try checkIntegrity()
                let segmentPaths = report.sealedSegmentPaths.map { entry -> [String: Any] in
                    ["path": entry.path, "status": entry.status]
                }
                let reportDict: [String: Any] = [
                    "stale_segment_refs": NSNumber(value: report.staleSegmentRefs),
                    "total_events": NSNumber(value: report.totalEvents),
                    "events_with_segment_id": NSNumber(value: report.eventsWithSegmentId),
                    "segments_count": NSNumber(value: report.segmentsCount),
                    "video_segments_count": NSNumber(value: report.videoSegmentsCount),
                    "audio_segments_count": NSNumber(value: report.audioSegmentsCount),
                    "ordering_violations": NSNumber(value: report.orderingViolations),
                    "sealed_segment_paths": segmentPaths,
                ]
                let reportData = try JSONSerialization.data(
                    withJSONObject: reportDict, options: [.prettyPrinted, .sortedKeys]
                )
                try reportData.write(to: bundleDir.appendingPathComponent("integrity_report.json"))
            } catch {
                logger.error("Failed to generate integrity report: \(error, privacy: .public)")
            }

            logger.info("Diagnostics bundle exported to: \(bundleDir.path)")
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: bundleDir.path)
        } catch {
            logger.error("Failed to export diagnostics bundle: \(error, privacy: .public)")
        }
    }
}
