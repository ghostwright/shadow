import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProactiveStore")

/// JSON-backed persistence for proactive suggestions, feedback, and run records.
/// Thread-safe via NSLock. Stores under `~/.shadow/data/proactive/`.
final class ProactiveStore: @unchecked Sendable {

    private let lock = NSLock()
    private let suggestionsDir: String
    private let feedbackDir: String
    private let runRecordsDir: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// In-memory caches (loaded lazily, written through).
    private var suggestions: [ProactiveSuggestion]?
    private var feedback: [ProactiveFeedback]?
    private var runRecords: [ProactiveRunRecord]?

    static let maxRunRecords = 200

    /// Initialize with a custom base directory (for testing) or the default data path.
    init(baseDir: String? = nil) {
        let base = baseDir ?? ProactiveStore.defaultBaseDir()
        self.suggestionsDir = (base as NSString).appendingPathComponent("suggestions")
        self.feedbackDir = (base as NSString).appendingPathComponent("feedback")
        self.runRecordsDir = (base as NSString).appendingPathComponent("runs")

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        ensureDirectories()
    }

    // MARK: - Suggestions

    /// Save a suggestion. Overwrites if same ID exists.
    func saveSuggestion(_ suggestion: ProactiveSuggestion) {
        lock.lock()
        defer { lock.unlock() }

        var list = loadSuggestionsLocked()
        if let idx = list.firstIndex(where: { $0.id == suggestion.id }) {
            list[idx] = suggestion
        } else {
            list.append(suggestion)
        }
        suggestions = list
        writeSuggestionsLocked(list)
    }

    /// List all suggestions, newest first.
    func listSuggestions() -> [ProactiveSuggestion] {
        lock.lock()
        defer { lock.unlock() }
        return loadSuggestionsLocked().sorted { $0.createdAt > $1.createdAt }
    }

    /// Find a suggestion by ID.
    func findSuggestion(id: UUID) -> ProactiveSuggestion? {
        lock.lock()
        defer { lock.unlock() }
        return loadSuggestionsLocked().first { $0.id == id }
    }

    /// Update suggestion status.
    func updateSuggestionStatus(id: UUID, status: SuggestionStatus) {
        lock.lock()
        defer { lock.unlock() }

        var list = loadSuggestionsLocked()
        if let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].status = status
            suggestions = list
            writeSuggestionsLocked(list)
        }
    }

    // MARK: - Feedback

    /// Save a feedback event.
    func saveFeedback(_ fb: ProactiveFeedback) {
        lock.lock()
        defer { lock.unlock() }

        var list = loadFeedbackLocked()
        list.append(fb)
        feedback = list
        writeFeedbackLocked(list)
    }

    /// List all feedback, newest first.
    func listFeedback() -> [ProactiveFeedback] {
        lock.lock()
        defer { lock.unlock() }
        return loadFeedbackLocked().sorted { $0.timestamp > $1.timestamp }
    }

    /// List feedback for a specific suggestion.
    func feedbackForSuggestion(id: UUID) -> [ProactiveFeedback] {
        lock.lock()
        defer { lock.unlock() }
        return loadFeedbackLocked().filter { $0.suggestionId == id }
    }

    // MARK: - Run Records

    /// Save a run record. Overwrites if same ID exists. Caps at maxRunRecords.
    func saveRunRecord(_ record: ProactiveRunRecord) {
        lock.lock()
        defer { lock.unlock() }

        var list = loadRunRecordsLocked()
        if let idx = list.firstIndex(where: { $0.id == record.id }) {
            list[idx] = record
        } else {
            list.append(record)
        }

        // Cap: keep newest by startedAt
        if list.count > Self.maxRunRecords {
            list.sort { $0.startedAt > $1.startedAt }
            list = Array(list.prefix(Self.maxRunRecords))
        }

        runRecords = list
        writeRunRecordsLocked(list)
    }

    /// List run records, newest first.
    func listRunRecords() -> [ProactiveRunRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadRunRecordsLocked().sorted { $0.startedAt > $1.startedAt }
    }

    /// Count of run records.
    func runRecordCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return loadRunRecordsLocked().count
    }

    // MARK: - Private: Suggestions I/O

    private func loadSuggestionsLocked() -> [ProactiveSuggestion] {
        if let cached = suggestions { return cached }
        let loaded = loadJSONFile([ProactiveSuggestion].self, dir: suggestionsDir, filename: "suggestions.json") ?? []
        suggestions = loaded
        return loaded
    }

    private func writeSuggestionsLocked(_ list: [ProactiveSuggestion]) {
        writeJSONFile(list, dir: suggestionsDir, filename: "suggestions.json")
    }

    // MARK: - Private: Feedback I/O

    private func loadFeedbackLocked() -> [ProactiveFeedback] {
        if let cached = feedback { return cached }
        let loaded = loadJSONFile([ProactiveFeedback].self, dir: feedbackDir, filename: "feedback.json") ?? []
        feedback = loaded
        return loaded
    }

    private func writeFeedbackLocked(_ list: [ProactiveFeedback]) {
        writeJSONFile(list, dir: feedbackDir, filename: "feedback.json")
    }

    // MARK: - Private: Run Records I/O

    private func loadRunRecordsLocked() -> [ProactiveRunRecord] {
        if let cached = runRecords { return cached }
        let loaded = loadJSONFile([ProactiveRunRecord].self, dir: runRecordsDir, filename: "run_records.json") ?? []
        runRecords = loaded
        return loaded
    }

    private func writeRunRecordsLocked(_ list: [ProactiveRunRecord]) {
        writeJSONFile(list, dir: runRecordsDir, filename: "run_records.json")
    }

    // MARK: - Private: Generic JSON I/O

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
        for dir in [suggestionsDir, feedbackDir, runRecordsDir] {
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
    }

    private static func defaultBaseDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".shadow/data/proactive").path
    }
}
