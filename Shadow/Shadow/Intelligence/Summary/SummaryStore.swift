import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SummaryStore")

/// JSON file persistence for meeting summaries.
///
/// Stores summaries under `~/.shadow/data/summaries/{id}.json`.
/// Summaries are infrequent (~1/meeting) and small (~5KB each),
/// so JSON files are appropriate — no database needed.
final class SummaryStore: Sendable {
    private let directory: String

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        self.directory = "\(homeDir)/.shadow/data/summaries"
    }

    /// For testing — allows custom directory.
    init(directory: String) {
        self.directory = directory
    }

    /// Save a summary to disk. Overwrites if ID already exists.
    func save(_ summary: MeetingSummary) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(summary)
        let path = filePath(for: summary.id)
        try data.write(to: URL(fileURLWithPath: path))

        logger.info("Saved summary \(summary.id) to \(path)")
    }

    /// Load a summary by ID. Returns nil if not found.
    func load(id: String) -> MeetingSummary? {
        let path = filePath(for: id)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(MeetingSummary.self, from: data)
        } catch {
            logger.error("Failed to load summary \(id): \(error, privacy: .public)")
            return nil
        }
    }

    /// List all saved summaries, sorted by generatedAt descending.
    func listAll() -> [MeetingSummary] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var summaries: [MeetingSummary] = []
        for file in files where file.hasSuffix(".json") {
            let path = "\(directory)/\(file)"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let summary = try? decoder.decode(MeetingSummary.self, from: data) {
                summaries.append(summary)
            }
        }

        return summaries.sorted { $0.metadata.generatedAt > $1.metadata.generatedAt }
    }

    /// Delete a summary by ID.
    func delete(id: String) -> Bool {
        let path = filePath(for: id)
        do {
            try FileManager.default.removeItem(atPath: path)
            logger.info("Deleted summary \(id)")
            return true
        } catch {
            logger.warning("Failed to delete summary \(id): \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Private

    private func filePath(for id: String) -> String {
        // Sanitize ID to prevent path traversal
        let safe = id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return "\(directory)/\(safe).json"
    }
}
