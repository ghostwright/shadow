import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "TrainingDataGenerator")

/// Generates grounding training data from Shadow's enriched event recordings.
///
/// Converts (screenshot, AX_state, click_coordinates, clicked_element) tuples
/// into JSONL training files suitable for LoRA fine-tuning of a grounding VLM.
///
/// Training tuple format (JSONL):
/// ```json
/// {"messages": [
///   {"role": "user", "content": [
///     {"type": "image", "image": "frames/1772168544.jpg"},
///     {"type": "text", "text": "Click the \"Compose\" button"}
///   ]},
///   {"role": "assistant", "content": "click(x=0.35, y=0.72)"}
/// ]}
/// ```
///
/// Instruction generation strategies (from GroundCUA research):
/// - **Direct:** "Click the button labeled 'Compose'" (from AX title)
/// - **Functional:** "Start writing a new email" (from inferred intent)
/// - **Spatial:** "Click the large button in the top-left sidebar" (from position)
///
/// Mimicry Phase B: Training Data Pipeline.
actor TrainingDataGenerator {

    /// Base directory for training data output.
    private let trainingDir: URL

    /// Directory for extracted video frames.
    private let framesDir: URL

    /// Directory for grounding training JSONL files.
    private let groundingDir: URL

    /// Total tuples generated this session.
    private(set) var tuplesGenerated: Int = 0

    /// Total tuples skipped (no frame available, missing data).
    private(set) var tuplesSkipped: Int = 0

    // MARK: - Init

    init(dataDir: URL? = nil) {
        let base = dataDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shadow/data/training")
        self.trainingDir = base
        self.framesDir = base.appendingPathComponent("frames")
        self.groundingDir = base.appendingPathComponent("grounding")
    }

    // MARK: - Generation

    /// Generate grounding training tuples from recent enriched click events.
    ///
    /// For each enriched mouse_down event (has ax_role and ax_title):
    /// 1. Extract the video frame closest to the click timestamp
    /// 2. Generate 1-3 instruction variants (direct, functional, spatial)
    /// 3. Write as JSONL training tuple
    ///
    /// - Parameters:
    ///   - lookbackHours: How far back to scan for events (default: 24)
    ///   - maxTuples: Maximum tuples to generate per run (default: 500)
    /// - Returns: Number of tuples generated
    @discardableResult
    func generateFromRecentEvents(
        lookbackHours: UInt32 = 24,
        maxTuples: Int = 500
    ) async -> Int {
        do {
            try ensureDirectories()
        } catch {
            logger.error("Failed to create training directories: \(error, privacy: .public)")
            return 0
        }

        // Fetch enriched click events from the behavioral search index
        let events: [BehavioralAction]
        do {
            let sequences = try searchBehavioralContext(
                query: "",
                targetApp: "",
                maxResults: 50
            )
            events = sequences.flatMap { $0.actions }
                .filter { $0.axRole != nil && $0.axTitle != nil }
        } catch {
            logger.warning("Failed to fetch enriched events: \(error, privacy: .public)")
            return 0
        }

        guard !events.isEmpty else {
            logger.debug("No enriched click events found for training data generation")
            return 0
        }

        var generated = 0
        let outputFile = groundingDir.appendingPathComponent("grounding-\(dateString()).jsonl")

        var jsonLines: [String] = []

        for event in events.prefix(maxTuples) {
            guard let role = event.axRole, let title = event.axTitle else {
                tuplesSkipped += 1
                continue
            }

            // Try to extract a video frame for this timestamp
            let frameFilename = "frame-\(event.ts).jpg"
            let framePath = framesDir.appendingPathComponent(frameFilename)

            let frameExists = FileManager.default.fileExists(atPath: framePath.path)
            if !frameExists {
                // Try to extract frame from video segment
                let extracted = extractFrame(
                    timestampUs: event.ts,
                    outputPath: framePath
                )
                if !extracted {
                    tuplesSkipped += 1
                    continue
                }
            }

            // Generate instruction variants
            let instructions = generateInstructions(
                role: role,
                title: title,
                identifier: event.axIdentifier
            )

            // We need normalized coordinates. Without the actual click coordinates
            // in the index, we cannot generate precise training tuples.
            guard let x = event.x, let y = event.y else {
                // Generate a partial tuple with just the instruction and frame reference
                for instruction in instructions {
                    let tuple = TrainingTuple(
                        imagePath: "frames/\(frameFilename)",
                        instruction: instruction,
                        response: "click(x=unknown, y=unknown)",
                        timestampUs: event.ts,
                        axRole: role,
                        axTitle: title,
                        needsCoordinates: true
                    )
                    if let json = tuple.toJSONLine() {
                        jsonLines.append(json)
                        generated += 1
                    }
                }
                continue
            }

            // Full training tuple with coordinates
            // Normalize coordinates against the main screen's point dimensions.
            // CGEvent coordinates are in the global display coordinate space (points).
            let screenSize = await MainActor.run {
                NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
            }
            let nx = Double(x) / screenSize.width
            let ny = Double(y) / screenSize.height

            for instruction in instructions {
                let tuple = TrainingTuple(
                    imagePath: "frames/\(frameFilename)",
                    instruction: instruction,
                    response: "click(x=\(String(format: "%.4f", nx)), y=\(String(format: "%.4f", ny)))",
                    timestampUs: event.ts,
                    axRole: role,
                    axTitle: title,
                    needsCoordinates: false
                )
                if let json = tuple.toJSONLine() {
                    jsonLines.append(json)
                    generated += 1
                }
            }
        }

        // Write JSONL file
        if !jsonLines.isEmpty {
            let content = jsonLines.joined(separator: "\n") + "\n"
            do {
                try content.write(to: outputFile, atomically: true, encoding: .utf8)
                logger.info("Training data: wrote \(generated) tuples to \(outputFile.lastPathComponent)")
            } catch {
                logger.error("Failed to write training data: \(error, privacy: .public)")
            }
        }

        tuplesGenerated += generated
        DiagnosticsStore.shared.increment("training_tuples_generated_total", by: Int64(generated))
        return generated
    }

    /// Get the total number of training tuples across all JSONL files.
    func totalTupleCount() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: groundingDir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> Int? in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            }
            .reduce(0, +)
    }

    // MARK: - Instruction Generation

    /// Generate 1-3 instruction variants for a training tuple.
    ///
    /// Inspired by GroundCUA's multi-style instruction generation:
    /// - Direct: describes the element by its visual/semantic label
    /// - Functional: describes what the element DOES
    /// - Spatial: describes WHERE the element is on screen
    private func generateInstructions(
        role: String,
        title: String,
        identifier: String?
    ) -> [String] {
        var instructions: [String] = []

        // Direct instruction: "Click the [role] labeled '[title]'"
        let roleDisplay = role.replacingOccurrences(of: "AX", with: "")
        instructions.append("Click the \(roleDisplay.lowercased()) labeled \"\(title)\"")

        // Alternative direct: shorter form
        if !title.isEmpty {
            instructions.append("Click \"\(title)\"")
        }

        return instructions
    }

    // MARK: - Frame Extraction

    /// Extract a video frame closest to the given timestamp.
    ///
    /// Uses the existing video segment index (Rust FFI) to find the video file
    /// containing the timestamp and AVAssetImageGenerator to extract the nearest frame.
    private func extractFrame(timestampUs: UInt64, outputPath: URL) -> Bool {
        do {
            // Try the main display first, then any display with a segment at this timestamp.
            // CGMainDisplayID() returns the system's primary display.
            let mainDisplayId = CGMainDisplayID()
            var segment = try findVideoSegment(displayId: UInt32(mainDisplayId), timestampUs: timestampUs)
            if segment == nil {
                // Fallback: try display ID 1 (common default)
                segment = try findVideoSegment(displayId: 1, timestampUs: timestampUs)
            }
            guard let segment else {
                return false
            }
            let filePath = segment.filePath

            // Use AVFoundation to extract the frame
            let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 1)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 1)

            // Calculate seek time relative to segment start
            let seekTimeUs = timestampUs - segment.startTs
            let seekTime = CMTime(value: Int64(seekTimeUs), timescale: 1_000_000)

            var actualTime = CMTime.zero
            let cgImage = try generator.copyCGImage(at: seekTime, actualTime: &actualTime)

            // Save as JPEG
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            guard let tiffData = nsImage.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiffData),
                  let jpegData = rep.representation(
                      using: .jpeg,
                      properties: [.compressionFactor: NSNumber(value: 0.8)]
                  )
            else {
                return false
            }

            try jpegData.write(to: outputPath)
            return true
        } catch {
            // Frame extraction failure is expected for many timestamps
            // (no video segment, corrupted segment, etc.)
            return false
        }
    }

    // MARK: - Helpers

    private func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: groundingDir, withIntermediateDirectories: true)
    }

    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

// MARK: - Training Tuple

/// A single grounding training example.
private struct TrainingTuple {
    let imagePath: String
    let instruction: String
    let response: String
    let timestampUs: UInt64
    let axRole: String
    let axTitle: String
    let needsCoordinates: Bool

    /// Serialize to a JSONL line in the mlx-vlm training format.
    func toJSONLine() -> String? {
        let messageDict: [String: Any] = [
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "image", "image": imagePath],
                        ["type": "text", "text": instruction]
                    ]
                ],
                [
                    "role": "assistant",
                    "content": response
                ]
            ],
            "metadata": [
                "timestamp_us": timestampUs,
                "ax_role": axRole,
                "ax_title": axTitle,
                "needs_coordinates": needsCoordinates
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: messageDict, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
