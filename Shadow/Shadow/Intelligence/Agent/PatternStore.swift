import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "PatternStore")

// MARK: - Pattern Data Model

/// A generalized tool-call pattern extracted from a successful agent run.
/// Stored locally and injected into future agent prompts when relevant.
struct AgentPattern: Codable, Sendable, Identifiable {
    let id: String
    /// Generalized task description (e.g., "Add item to Amazon cart").
    let taskDescription: String
    /// Primary app the pattern targets (e.g., "Google Chrome").
    let targetApp: String
    /// Optional URL regex pattern (e.g., "amazon\\.com").
    let urlPattern: String?
    /// Generalized tool call sequence.
    let toolSequence: [PatternStep]
    /// Agent observations and lessons learned.
    let notes: [String]
    /// Number of times this pattern was reused successfully.
    var successCount: Int
    /// Number of times this pattern was reused and the run failed.
    var failureCount: Int
    /// Creation timestamp (Unix microseconds).
    let createdAt: UInt64
    /// Last time this pattern was used (Unix microseconds).
    var lastUsedAt: UInt64
    /// Whether this pattern has been archived due to decay.
    var archived: Bool
}

/// A single step in a generalized tool-call pattern.
struct PatternStep: Codable, Sendable {
    /// Tool name (e.g., "ax_focus_app").
    let toolName: String
    /// Purpose of this step (e.g., "Navigate to Amazon").
    let purpose: String
    /// Key arguments with generalized placeholders (e.g., "{{QUERY}}").
    let keyArguments: [String: String]
    /// Expected outcome after this step (e.g., "Page shows product listings").
    let expectedOutcome: String?
}

// MARK: - Pattern Store

/// Manages persistence and retrieval of agent patterns.
///
/// Patterns are stored as individual JSON files in `~/.shadow/data/patterns/`.
/// The store maintains an in-memory index for fast lookups and lazy-loads
/// patterns from disk on first access.
///
/// Thread safety: the store is designed for single-threaded access from the
/// agent pipeline. Callers should serialize access (e.g., via Task).
final class PatternStore: @unchecked Sendable {

    /// Directory where pattern JSON files are stored.
    private let directory: URL

    /// In-memory index of all patterns, loaded lazily.
    private let _patterns: MutableBox<[String: AgentPattern]>

    /// Whether patterns have been loaded from disk.
    private let _loaded: MutableBox<Bool>

    /// Thread-safe mutable box for use in Sendable context.
    private final class MutableBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Initialize with a specific directory. Defaults to `~/.shadow/data/patterns/`.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shadow/data/patterns")
        self.directory = dir
        self._patterns = MutableBox([:])
        self._loaded = MutableBox(false)
    }

    // MARK: - CRUD

    /// Load all patterns from disk (idempotent). Call before queries.
    func loadIfNeeded() {
        guard !_loaded.value else { return }
        _loaded.value = true

        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            logger.debug("Pattern directory does not exist yet — no patterns to load")
            return
        }

        do {
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            let decoder = JSONDecoder()
            for file in files {
                do {
                    let data = try Data(contentsOf: file)
                    let pattern = try decoder.decode(AgentPattern.self, from: data)
                    if !pattern.archived {
                        _patterns.value[pattern.id] = pattern
                    }
                } catch {
                    logger.warning("Failed to load pattern at \(file.lastPathComponent): \(error, privacy: .public)")
                }
            }
            logger.info("Loaded \(self._patterns.value.count) patterns from disk")
        } catch {
            logger.error("Failed to enumerate pattern directory: \(error, privacy: .public)")
        }
    }

    /// Save a new pattern. Deduplicates by app + similar task.
    func save(_ pattern: AgentPattern) {
        loadIfNeeded()

        // Dedup: check if a similar pattern already exists
        if let existing = findSimilar(pattern) {
            logger.debug("Similar pattern '\(existing.taskDescription)' already exists — skipping save")
            return
        }

        _patterns.value[pattern.id] = pattern
        writeToDisk(pattern)
        logger.info("Saved pattern '\(pattern.taskDescription)' for app '\(pattern.targetApp)'")
    }

    /// Get a pattern by ID.
    func get(_ id: String) -> AgentPattern? {
        loadIfNeeded()
        return _patterns.value[id]
    }

    /// Update an existing pattern (e.g., increment success/failure counts).
    func update(_ pattern: AgentPattern) {
        _patterns.value[pattern.id] = pattern
        writeToDisk(pattern)
    }

    /// Mark a pattern as archived. Removes from in-memory index.
    func archive(_ id: String) {
        guard var pattern = _patterns.value[id] else { return }
        pattern.archived = true
        _patterns.value.removeValue(forKey: id)
        writeToDisk(pattern)
        logger.info("Archived pattern '\(pattern.taskDescription)'")
    }

    /// All non-archived patterns.
    var allPatterns: [AgentPattern] {
        loadIfNeeded()
        return Array(_patterns.value.values)
    }

    /// Number of loaded patterns.
    var count: Int {
        _patterns.value.count
    }

    // MARK: - Search

    /// Find patterns relevant to a query. Returns up to `limit` patterns
    /// ranked by relevance score * success ratio.
    func findRelevant(query: String, targetApp: String? = nil, limit: Int = 3) -> [AgentPattern] {
        loadIfNeeded()

        let queryWords = Set(query.lowercased().split(separator: " ").map(String.init))
        guard !queryWords.isEmpty else { return [] }

        var scored: [(pattern: AgentPattern, score: Double)] = []

        for pattern in _patterns.value.values {
            // Decay check: skip patterns with too many failures
            if pattern.failureCount > pattern.successCount * 2 && pattern.failureCount > 2 {
                continue
            }

            var score = 0.0

            // Keyword overlap between query and task description
            let taskWords = Set(pattern.taskDescription.lowercased().split(separator: " ").map(String.init))
            let overlap = queryWords.intersection(taskWords).count
            if overlap > 0 {
                score += Double(overlap) / Double(max(queryWords.count, taskWords.count))
            }

            // App name match (bonus)
            if let targetApp, pattern.targetApp.localizedCaseInsensitiveContains(targetApp) {
                score += 0.3
            }

            // Also check if query mentions the app
            let patternAppLower = pattern.targetApp.lowercased()
            if queryWords.contains(where: { patternAppLower.contains($0) }) {
                score += 0.2
            }

            // Notes keyword overlap
            let noteWords = Set(pattern.notes.joined(separator: " ").lowercased()
                .split(separator: " ").map(String.init))
            let noteOverlap = queryWords.intersection(noteWords).count
            if noteOverlap > 0 {
                score += Double(noteOverlap) * 0.1
            }

            // Success ratio multiplier
            let totalUses = pattern.successCount + pattern.failureCount
            if totalUses > 0 {
                let ratio = Double(pattern.successCount) / Double(totalUses)
                score *= (0.5 + ratio * 0.5) // Scale: 0.5x at 0% to 1.0x at 100%
            }

            // Recency bonus (patterns used recently score slightly higher)
            let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let ageHours = Double(nowUs - pattern.lastUsedAt) / (3_600_000_000)
            if ageHours < 24 {
                score += 0.1
            }

            if score > 0.1 {
                scored.append((pattern, score))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.pattern)
    }

    // MARK: - Helpers

    /// Find a similar existing pattern (same app + high word overlap in task).
    private func findSimilar(_ pattern: AgentPattern) -> AgentPattern? {
        let newWords = Set(pattern.taskDescription.lowercased().split(separator: " ").map(String.init))

        for existing in _patterns.value.values {
            guard existing.targetApp == pattern.targetApp else { continue }
            let existingWords = Set(existing.taskDescription.lowercased().split(separator: " ").map(String.init))
            let overlap = newWords.intersection(existingWords).count
            let similarity = Double(overlap) / Double(max(newWords.count, existingWords.count))
            if similarity > 0.7 {
                return existing
            }
        }
        return nil
    }

    /// Write a pattern to disk as JSON.
    private func writeToDisk(_ pattern: AgentPattern) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create pattern directory: \(error, privacy: .public)")
                return
            }
        }

        let file = directory.appendingPathComponent("\(pattern.id).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(pattern)
            try data.write(to: file, options: .atomic)
        } catch {
            logger.error("Failed to write pattern \(pattern.id): \(error, privacy: .public)")
        }
    }

    // MARK: - Pattern Prompt Formatting

    /// Format patterns for injection into the agent system prompt.
    /// Returns empty string if no patterns match.
    static func formatPatternsForPrompt(_ patterns: [AgentPattern]) -> String {
        guard !patterns.isEmpty else { return "" }

        var lines: [String] = ["# Relevant Patterns (from previous successful runs)\n"]

        for (i, pattern) in patterns.enumerated() {
            let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let ageHours = Int(Double(nowUs - pattern.lastUsedAt) / 3_600_000_000)
            let ageStr = ageHours < 1 ? "just now" : ageHours < 24 ? "\(ageHours)h ago" : "\(ageHours / 24)d ago"

            lines.append("PATTERN \(i + 1): \"\(pattern.taskDescription)\" [success: \(pattern.successCount), last: \(ageStr)]")
            var appLine = "App: \(pattern.targetApp)"
            if let urlPattern = pattern.urlPattern {
                appLine += " | URL: \(urlPattern)"
            }
            lines.append(appLine)

            // Compact step summary
            let stepSummary = pattern.toolSequence
                .map { "\($0.toolName)(\($0.purpose))" }
                .joined(separator: " -> ")
            lines.append("Steps: \(stepSummary)")

            if !pattern.notes.isEmpty {
                lines.append("Notes: \(pattern.notes.joined(separator: ". "))")
            }
            lines.append("")
        }

        lines.append("Use these patterns as guidance. Adapt them to the current task — don't follow blindly if the situation differs.")

        return lines.joined(separator: "\n")
    }
}
