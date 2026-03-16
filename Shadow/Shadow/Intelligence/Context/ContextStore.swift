import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ContextStore")

/// JSON-backed persistence for context memory records and heartbeat checkpoints.
/// Thread-safe via NSLock. Stores under `~/.shadow/data/context/`.
final class ContextStore: @unchecked Sendable {

    private let lock = NSLock()
    private let episodesDir: String
    private let daysDir: String
    private let weeksDir: String
    private let indicesDir: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// In-memory checkpoint cache.
    private var checkpoint: HeartbeatCheckpoint?

    /// Initialize with a custom base directory (for testing) or the default data path.
    init(baseDir: String? = nil) {
        let base = baseDir ?? ContextStore.defaultBaseDir()
        self.episodesDir = (base as NSString).appendingPathComponent("episodes")
        self.daysDir = (base as NSString).appendingPathComponent("days")
        self.weeksDir = (base as NSString).appendingPathComponent("weeks")
        self.indicesDir = (base as NSString).appendingPathComponent("indices")

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        ensureDirectories()
    }

    // MARK: - Episodes

    /// Save an episode record.
    func saveEpisode(_ episode: EpisodeRecord) {
        lock.lock()
        defer { lock.unlock() }
        let filename = "\(episode.id.uuidString).json"
        writeJSONFile(episode, dir: episodesDir, filename: filename)
    }

    /// List all episodes, sorted by startUs descending.
    func listEpisodes() -> [EpisodeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadAllJSONFiles(EpisodeRecord.self, dir: episodesDir)
            .sorted {
                if $0.startUs != $1.startUs { return $0.startUs > $1.startUs }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// Find an episode by ID.
    func findEpisode(id: UUID) -> EpisodeRecord? {
        lock.lock()
        defer { lock.unlock() }
        let filename = "\(id.uuidString).json"
        return loadJSONFile(EpisodeRecord.self, dir: episodesDir, filename: filename)
    }

    /// List episodes overlapping a time range.
    func episodesInRange(startUs: UInt64, endUs: UInt64) -> [EpisodeRecord] {
        listEpisodes().filter { $0.endUs >= startUs && $0.startUs <= endUs }
    }

    // MARK: - Daily Records

    /// Save a daily record.
    func saveDaily(_ daily: DailyRecord) {
        lock.lock()
        defer { lock.unlock() }
        let filename = "\(daily.date).json"
        writeJSONFile(daily, dir: daysDir, filename: filename)
    }

    /// Load a daily record by date string.
    func findDaily(date: String) -> DailyRecord? {
        lock.lock()
        defer { lock.unlock() }
        let filename = "\(date).json"
        return loadJSONFile(DailyRecord.self, dir: daysDir, filename: filename)
    }

    /// List all daily records, sorted by date descending.
    func listDailies() -> [DailyRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadAllJSONFiles(DailyRecord.self, dir: daysDir)
            .sorted { $0.date > $1.date }
    }

    // MARK: - Weekly Records

    /// Save a weekly record.
    func saveWeekly(_ weekly: WeeklyRecord) {
        lock.lock()
        defer { lock.unlock() }
        let filename = "\(weekly.weekId).json"
        writeJSONFile(weekly, dir: weeksDir, filename: filename)
    }

    /// Load a weekly record by week ID.
    func findWeekly(weekId: String) -> WeeklyRecord? {
        lock.lock()
        defer { lock.unlock() }
        let filename = "\(weekId).json"
        return loadJSONFile(WeeklyRecord.self, dir: weeksDir, filename: filename)
    }

    /// List all weekly records, sorted by weekId descending.
    func listWeeklies() -> [WeeklyRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadAllJSONFiles(WeeklyRecord.self, dir: weeksDir)
            .sorted { $0.weekId > $1.weekId }
    }

    // MARK: - Checkpoint

    /// Load the heartbeat checkpoint, or return empty if none exists.
    func loadCheckpoint() -> HeartbeatCheckpoint {
        lock.lock()
        defer { lock.unlock() }
        if let cached = checkpoint { return cached }
        let loaded = loadJSONFile(HeartbeatCheckpoint.self, dir: indicesDir, filename: "checkpoints.json")
            ?? .empty
        checkpoint = loaded
        return loaded
    }

    /// Save the heartbeat checkpoint.
    func saveCheckpoint(_ cp: HeartbeatCheckpoint) {
        lock.lock()
        defer { lock.unlock() }
        checkpoint = cp
        writeJSONFile(cp, dir: indicesDir, filename: "checkpoints.json")
    }

    // MARK: - Private: JSON I/O

    private func loadJSONFile<T: Decodable>(_ type: T.Type, dir: String, filename: String) -> T? {
        let path = (dir as NSString).appendingPathComponent(filename)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            logger.error("Failed to decode \(filename): \(error, privacy: .public)")
            return nil
        }
    }

    private func loadAllJSONFiles<T: Decodable>(_ type: T.Type, dir: String) -> [T] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return files.compactMap { filename -> T? in
            guard filename.hasSuffix(".json") else { return nil }
            return loadJSONFile(type, dir: dir, filename: filename)
        }
    }

    private func writeJSONFile<T: Encodable>(_ value: T, dir: String, filename: String) {
        let path = (dir as NSString).appendingPathComponent(filename)
        do {
            let data = try encoder.encode(value)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            logger.error("Failed to write \(filename): \(error, privacy: .public)")
        }
    }

    private func ensureDirectories() {
        let fm = FileManager.default
        for dir in [episodesDir, daysDir, weeksDir, indicesDir] {
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }

    private static func defaultBaseDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".shadow/data/context").path
    }
}
