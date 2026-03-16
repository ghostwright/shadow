import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProcedureStore")

// MARK: - Procedure Store

/// Persists procedures as JSON files under `~/.shadow/data/procedures/`
/// and maintains a SQLite index via the Rust timeline module.
///
/// Thread-safe via actor isolation.
actor ProcedureStore {

    private let proceduresDir: URL

    init() {
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shadow/data/procedures", isDirectory: true)
        self.proceduresDir = dataDir
    }

    /// Initialize with a custom directory (for testing).
    init(directory: URL) {
        self.proceduresDir = directory
    }

    // MARK: - CRUD

    /// Save a procedure template to disk and index it.
    func save(_ procedure: ProcedureTemplate) throws {
        try ensureDirectory()

        let filename = "\(procedure.id).json"
        let fileURL = proceduresDir.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(procedure)
        try data.write(to: fileURL, options: .atomic)

        logger.info("Saved procedure '\(procedure.name)' to \(filename)")

        // Index in SQLite
        try indexProcedure(procedure)
    }

    /// Load a procedure by ID.
    func load(id: String) throws -> ProcedureTemplate? {
        let fileURL = proceduresDir.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ProcedureTemplate.self, from: data)
    }

    /// Update an existing procedure.
    func update(_ procedure: ProcedureTemplate) throws {
        var updated = procedure
        updated.updatedAt = CaptureSessionClock.wallMicros()
        try save(updated)
    }

    /// Delete a procedure by ID.
    func delete(id: String) throws {
        let fileURL = proceduresDir.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Deleted procedure \(id)")
        }
    }

    /// List all saved procedures.
    func listAll() -> [ProcedureTemplate] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: proceduresDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ProcedureTemplate? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ProcedureTemplate.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Search procedures by name or description.
    func search(query: String) -> [ProcedureTemplate] {
        let queryLower = query.lowercased()
        return listAll().filter { proc in
            proc.name.lowercased().contains(queryLower)
            || proc.description.lowercased().contains(queryLower)
            || proc.tags.contains { $0.lowercased().contains(queryLower) }
            || proc.sourceApp.lowercased().contains(queryLower)
        }
    }

    /// Record a successful execution.
    func recordExecution(id: String) throws {
        guard var procedure = try load(id: id) else { return }
        procedure.executionCount += 1
        procedure.lastExecutedAt = CaptureSessionClock.wallMicros()
        try save(procedure)
    }

    // MARK: - Private Helpers

    /// Ensure the procedures directory exists.
    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: proceduresDir.path) {
            try FileManager.default.createDirectory(
                at: proceduresDir,
                withIntermediateDirectories: true
            )
        }
    }

    /// Index a procedure in SQLite for fast lookup.
    private func indexProcedure(_ procedure: ProcedureTemplate) throws {
        // Use the Rust timeline module for SQLite indexing
        do {
            try insertProcedure(
                id: procedure.id,
                name: procedure.name,
                description: procedure.description,
                sourceApp: procedure.sourceApp,
                sourceBundleId: procedure.sourceBundleId,
                stepCount: UInt32(procedure.steps.count),
                parameterCount: UInt32(procedure.parameters.count),
                tags: procedure.tags.joined(separator: ","),
                createdAt: procedure.createdAt,
                updatedAt: procedure.updatedAt
            )
        } catch {
            // SQLite index is derived — log but don't fail the save
            logger.warning("Failed to index procedure in SQLite: \(error.localizedDescription)")
        }
    }
}
