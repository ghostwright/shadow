use std::path::Path;

use log::info;
use rusqlite::{params, Connection};

/// Schema version for the vector index. Bump when schema changes.
const VECTOR_SCHEMA_VERSION: u32 = 1;
/// Embedding dimensionality for MobileCLIP-S2.
const EXPECTED_DIMENSION: usize = 512;

/// A single vector embedding entry to be indexed. Passed from Swift via UniFFI.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct VectorEntry {
    /// Wall-clock timestamp (Unix microseconds) of the frame this embedding represents.
    pub ts: u64,
    /// Display ID where the frame was captured.
    pub display_id: u32,
    /// Path to the video file containing this frame.
    pub file_path: String,
    /// Offset from segment start (microseconds) to locate the exact frame.
    pub frame_offset_us: u64,
    /// The embedding vector (f32 components, expected dimension: 512).
    pub vector: Vec<f32>,
}

/// A single vector search result returned to Swift via UniFFI.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct VectorSearchResult {
    /// Wall-clock timestamp of the matched frame.
    pub ts: u64,
    /// Display ID where the matched frame was captured.
    pub display_id: u32,
    /// Cosine similarity score (0.0–1.0 for normalized vectors).
    pub score: f32,
    /// Path to the video file containing this frame.
    pub file_path: String,
    /// Offset from segment start (microseconds).
    pub frame_offset_us: u64,
}

/// Vector index statistics for diagnostics.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct VectorIndexStats {
    pub total_embeddings: u64,
    pub dimension: u32,
    pub schema_version: u32,
}

/// SQLite-backed vector index with brute-force cosine similarity search.
///
/// Stores embeddings as BLOBs in a `vector_embeddings` table. Search loads
/// candidates and computes cosine similarity in Rust. Adequate for <100K
/// vectors. Can be replaced with an ANN backend (usearch) when scale demands it.
pub struct VectorIndex {
    conn: Connection,
    /// True if the index was rebuilt due to schema version change.
    rebuilt: bool,
}

/// Vector-specific error type.
#[derive(Debug, thiserror::Error)]
pub enum VectorError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("Dimension mismatch: expected {expected}, got {actual}")]
    DimensionMismatch { expected: usize, actual: usize },
    #[error("Vector I/O error: {0}")]
    IoError(String),
}

impl VectorIndex {
    /// Open or create a vector index at the given directory.
    /// Creates the SQLite database and tables if they don't exist.
    /// Rebuilds the index if the schema version has changed.
    pub fn new(index_dir: &Path) -> Result<Self, VectorError> {
        std::fs::create_dir_all(index_dir)
            .map_err(|e| VectorError::IoError(e.to_string()))?;

        let db_path = index_dir.join("vector_index.db");
        let version_file = index_dir.join("vector_schema_version");

        // Check schema version
        let mut rebuilt = false;
        if version_file.exists() {
            let stored = std::fs::read_to_string(&version_file)
                .unwrap_or_default()
                .trim()
                .parse::<u32>()
                .unwrap_or(0);
            if stored != VECTOR_SCHEMA_VERSION {
                info!(
                    "Vector schema version changed (want {}, have {}), rebuilding",
                    VECTOR_SCHEMA_VERSION, stored
                );
                // Remove old database to rebuild
                if db_path.exists() {
                    std::fs::remove_file(&db_path)
                        .map_err(|e| VectorError::IoError(e.to_string()))?;
                }
                rebuilt = true;
            }
        } else {
            rebuilt = !db_path.exists();
        }

        let conn = Connection::open(&db_path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS vector_embeddings (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                ts_wall_us      INTEGER NOT NULL,
                display_id      INTEGER NOT NULL,
                file_path       TEXT NOT NULL,
                frame_offset_us INTEGER NOT NULL,
                dimension       INTEGER NOT NULL,
                embedding       BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_vector_ts
                ON vector_embeddings(ts_wall_us);
            CREATE INDEX IF NOT EXISTS idx_vector_display
                ON vector_embeddings(display_id, ts_wall_us);",
        )?;

        // Write schema version
        std::fs::write(&version_file, VECTOR_SCHEMA_VERSION.to_string())
            .map_err(|e| VectorError::IoError(e.to_string()))?;

        info!(
            "Vector index opened at {} (schema v{}, rebuilt={})",
            db_path.display(),
            VECTOR_SCHEMA_VERSION,
            rebuilt
        );

        Ok(Self { conn, rebuilt })
    }

    /// Insert a batch of vector entries into the index.
    /// Returns the number of entries successfully inserted.
    pub fn insert_entries(&mut self, entries: &[VectorEntry]) -> Result<u32, VectorError> {
        if entries.is_empty() {
            return Ok(0);
        }

        let tx = self.conn.transaction()?;
        let mut count: u32 = 0;

        {
            let mut stmt = tx.prepare_cached(
                "INSERT INTO vector_embeddings (ts_wall_us, display_id, file_path, frame_offset_us, dimension, embedding)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )?;

            for entry in entries {
                if entry.vector.len() != EXPECTED_DIMENSION {
                    return Err(VectorError::DimensionMismatch {
                        expected: EXPECTED_DIMENSION,
                        actual: entry.vector.len(),
                    });
                }

                let blob = f32_slice_to_bytes(&entry.vector);

                stmt.execute(params![
                    entry.ts as i64,
                    entry.display_id,
                    entry.file_path,
                    entry.frame_offset_us as i64,
                    EXPECTED_DIMENSION as i64,
                    blob,
                ])?;
                count += 1;
            }
        }

        tx.commit()?;

        if count > 0 {
            info!("Indexed {} vector embeddings", count);
        }

        Ok(count)
    }

    /// Search for the top-k nearest neighbors to a query vector using cosine similarity.
    /// Returns results sorted by descending similarity score.
    pub fn search(
        &self,
        query_vector: &[f32],
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>, VectorError> {
        if query_vector.len() != EXPECTED_DIMENSION {
            return Err(VectorError::DimensionMismatch {
                expected: EXPECTED_DIMENSION,
                actual: query_vector.len(),
            });
        }

        let query_norm = l2_norm(query_vector);
        if query_norm < 1e-10 {
            return Ok(Vec::new());
        }

        let mut stmt = self.conn.prepare(
            "SELECT ts_wall_us, display_id, file_path, frame_offset_us, embedding
             FROM vector_embeddings",
        )?;

        let mut candidates: Vec<VectorSearchResult> = Vec::new();

        let rows = stmt.query_map([], |row| {
            let ts: i64 = row.get(0)?;
            let display_id: u32 = row.get(1)?;
            let file_path: String = row.get(2)?;
            let frame_offset_us: i64 = row.get(3)?;
            let blob: Vec<u8> = row.get(4)?;
            Ok((ts as u64, display_id, file_path, frame_offset_us as u64, blob))
        })?;

        for row_result in rows {
            let (ts, display_id, file_path, frame_offset_us, blob) = row_result?;
            let embedding = bytes_to_f32_slice(&blob);

            if embedding.len() != EXPECTED_DIMENSION {
                continue; // Skip corrupted entries
            }

            let score = cosine_similarity(query_vector, &embedding, query_norm);

            candidates.push(VectorSearchResult {
                ts,
                display_id,
                score,
                file_path,
                frame_offset_us,
            });
        }

        // Sort by score descending
        candidates.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        candidates.truncate(limit);

        Ok(candidates)
    }

    /// Search for the top-k nearest neighbors within a timestamp range.
    /// Only considers embeddings where `ts_wall_us` is between `start_us` and `end_us` (inclusive).
    /// Returns results sorted by descending similarity score.
    pub fn search_in_range(
        &self,
        query_vector: &[f32],
        start_us: u64,
        end_us: u64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>, VectorError> {
        if query_vector.len() != EXPECTED_DIMENSION {
            return Err(VectorError::DimensionMismatch {
                expected: EXPECTED_DIMENSION,
                actual: query_vector.len(),
            });
        }

        if start_us > end_us {
            return Ok(Vec::new());
        }

        let query_norm = l2_norm(query_vector);
        if query_norm < 1e-10 {
            return Ok(Vec::new());
        }

        let mut stmt = self.conn.prepare(
            "SELECT ts_wall_us, display_id, file_path, frame_offset_us, embedding
             FROM vector_embeddings
             WHERE ts_wall_us >= ?1 AND ts_wall_us <= ?2",
        )?;

        let mut candidates: Vec<VectorSearchResult> = Vec::new();

        let rows = stmt.query_map(params![start_us as i64, end_us as i64], |row| {
            let ts: i64 = row.get(0)?;
            let display_id: u32 = row.get(1)?;
            let file_path: String = row.get(2)?;
            let frame_offset_us: i64 = row.get(3)?;
            let blob: Vec<u8> = row.get(4)?;
            Ok((ts as u64, display_id, file_path, frame_offset_us as u64, blob))
        })?;

        for row_result in rows {
            let (ts, display_id, file_path, frame_offset_us, blob) = row_result?;
            let embedding = bytes_to_f32_slice(&blob);

            if embedding.len() != EXPECTED_DIMENSION {
                continue;
            }

            let score = cosine_similarity(query_vector, &embedding, query_norm);

            candidates.push(VectorSearchResult {
                ts,
                display_id,
                score,
                file_path,
                frame_offset_us,
            });
        }

        candidates.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        candidates.truncate(limit);

        Ok(candidates)
    }

    /// Get index statistics for diagnostics.
    pub fn stats(&self) -> Result<VectorIndexStats, VectorError> {
        let total: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM vector_embeddings", [], |row| {
                row.get(0)
            })?;

        Ok(VectorIndexStats {
            total_embeddings: total as u64,
            dimension: EXPECTED_DIMENSION as u32,
            schema_version: VECTOR_SCHEMA_VERSION,
        })
    }

    /// Returns true if the index was rebuilt due to schema version change.
    /// Callers should reset the vector checkpoint when this is true.
    pub fn was_rebuilt(&self) -> bool {
        self.rebuilt
    }

    /// Clear all embeddings from the index. Used for rebuild scenarios.
    pub fn clear(&mut self) -> Result<(), VectorError> {
        self.conn.execute("DELETE FROM vector_embeddings", [])?;
        info!("Vector index cleared");
        Ok(())
    }
}

// ---- Math utilities ----

/// Compute cosine similarity between two vectors.
/// `query_norm` is pre-computed for efficiency (same query, many candidates).
fn cosine_similarity(a: &[f32], b: &[f32], a_norm: f32) -> f32 {
    debug_assert_eq!(a.len(), b.len());

    let mut dot = 0.0f32;
    let mut b_norm_sq = 0.0f32;

    for i in 0..a.len() {
        dot += a[i] * b[i];
        b_norm_sq += b[i] * b[i];
    }

    let b_norm = b_norm_sq.sqrt();
    if b_norm < 1e-10 {
        return 0.0;
    }

    dot / (a_norm * b_norm)
}

/// Compute L2 norm of a vector.
fn l2_norm(v: &[f32]) -> f32 {
    v.iter().map(|x| x * x).sum::<f32>().sqrt()
}

/// Convert &[f32] to &[u8] for SQLite BLOB storage.
fn f32_slice_to_bytes(v: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(v.len() * 4);
    for &val in v {
        bytes.extend_from_slice(&val.to_le_bytes());
    }
    bytes
}

/// Convert &[u8] (from SQLite BLOB) back to Vec<f32>.
fn bytes_to_f32_slice(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_random_vector(seed: u64) -> Vec<f32> {
        // Deterministic pseudo-random vector for testing
        let mut v = Vec::with_capacity(EXPECTED_DIMENSION);
        let mut s = seed;
        for _ in 0..EXPECTED_DIMENSION {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1);
            v.push((s as f32 / u64::MAX as f32) * 2.0 - 1.0);
        }
        // Normalize
        let norm = l2_norm(&v);
        if norm > 0.0 {
            for x in &mut v {
                *x /= norm;
            }
        }
        v
    }

    #[test]
    fn test_insert_and_search() {
        let tmp = TempDir::new().unwrap();
        let mut index = VectorIndex::new(tmp.path()).unwrap();

        let v1 = make_random_vector(1);
        let v2 = make_random_vector(2);
        let v3 = make_random_vector(3);

        let entries = vec![
            VectorEntry {
                ts: 1000,
                display_id: 1,
                file_path: "seg1.mp4".into(),
                frame_offset_us: 0,
                vector: v1.clone(),
            },
            VectorEntry {
                ts: 2000,
                display_id: 1,
                file_path: "seg1.mp4".into(),
                frame_offset_us: 1_000_000,
                vector: v2.clone(),
            },
            VectorEntry {
                ts: 3000,
                display_id: 2,
                file_path: "seg2.mp4".into(),
                frame_offset_us: 0,
                vector: v3.clone(),
            },
        ];

        let count = index.insert_entries(&entries).unwrap();
        assert_eq!(count, 3);

        // Search with v1 as query — should return v1 as top result (self-similarity = 1.0)
        let results = index.search(&v1, 10).unwrap();
        assert_eq!(results.len(), 3);
        assert_eq!(results[0].ts, 1000);
        assert!((results[0].score - 1.0).abs() < 0.01, "Self-similarity should be ~1.0");

        // All scores should be valid
        for r in &results {
            assert!(r.score >= -1.0 && r.score <= 1.01);
        }
    }

    #[test]
    fn test_cosine_similarity_correctness() {
        let a = vec![1.0, 0.0, 0.0];
        let b = vec![1.0, 0.0, 0.0];
        assert!((cosine_similarity(&a, &b, l2_norm(&a)) - 1.0).abs() < 1e-6);

        let c = vec![0.0, 1.0, 0.0];
        assert!(cosine_similarity(&a, &c, l2_norm(&a)).abs() < 1e-6); // orthogonal

        let d = vec![-1.0, 0.0, 0.0];
        assert!((cosine_similarity(&a, &d, l2_norm(&a)) + 1.0).abs() < 1e-6); // opposite
    }

    #[test]
    fn test_dimension_mismatch_rejected() {
        let tmp = TempDir::new().unwrap();
        let mut index = VectorIndex::new(tmp.path()).unwrap();

        let bad_entry = VectorEntry {
            ts: 1000,
            display_id: 1,
            file_path: "seg.mp4".into(),
            frame_offset_us: 0,
            vector: vec![0.0; 128], // wrong dimension
        };

        let err = index.insert_entries(&[bad_entry]).unwrap_err();
        assert!(matches!(err, VectorError::DimensionMismatch { .. }));
    }

    #[test]
    fn test_search_dimension_mismatch() {
        let tmp = TempDir::new().unwrap();
        let index = VectorIndex::new(tmp.path()).unwrap();

        let bad_query = vec![0.0; 128];
        let err = index.search(&bad_query, 10).unwrap_err();
        assert!(matches!(err, VectorError::DimensionMismatch { .. }));
    }

    #[test]
    fn test_empty_index_search() {
        let tmp = TempDir::new().unwrap();
        let index = VectorIndex::new(tmp.path()).unwrap();

        let query = make_random_vector(42);
        let results = index.search(&query, 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_stats() {
        let tmp = TempDir::new().unwrap();
        let mut index = VectorIndex::new(tmp.path()).unwrap();

        let stats = index.stats().unwrap();
        assert_eq!(stats.total_embeddings, 0);
        assert_eq!(stats.dimension, EXPECTED_DIMENSION as u32);

        let entries = vec![VectorEntry {
            ts: 1000,
            display_id: 1,
            file_path: "seg.mp4".into(),
            frame_offset_us: 0,
            vector: make_random_vector(1),
        }];
        index.insert_entries(&entries).unwrap();

        let stats = index.stats().unwrap();
        assert_eq!(stats.total_embeddings, 1);
    }

    #[test]
    fn test_schema_version_rebuild() {
        let tmp = TempDir::new().unwrap();

        // Create index
        {
            let mut index = VectorIndex::new(tmp.path()).unwrap();
            let entries = vec![VectorEntry {
                ts: 1000,
                display_id: 1,
                file_path: "seg.mp4".into(),
                frame_offset_us: 0,
                vector: make_random_vector(1),
            }];
            index.insert_entries(&entries).unwrap();
            assert_eq!(index.stats().unwrap().total_embeddings, 1);
        }

        // Re-open — same version, should preserve data
        {
            let index = VectorIndex::new(tmp.path()).unwrap();
            assert_eq!(index.stats().unwrap().total_embeddings, 1);
            assert!(!index.was_rebuilt());
        }

        // Tamper version file to simulate upgrade
        let version_file = tmp.path().join("vector_schema_version");
        std::fs::write(&version_file, "0").unwrap();

        // Re-open — different version, should rebuild
        {
            let index = VectorIndex::new(tmp.path()).unwrap();
            assert_eq!(index.stats().unwrap().total_embeddings, 0);
            assert!(index.was_rebuilt());
        }
    }

    #[test]
    fn test_clear() {
        let tmp = TempDir::new().unwrap();
        let mut index = VectorIndex::new(tmp.path()).unwrap();

        let entries = vec![VectorEntry {
            ts: 1000,
            display_id: 1,
            file_path: "seg.mp4".into(),
            frame_offset_us: 0,
            vector: make_random_vector(1),
        }];
        index.insert_entries(&entries).unwrap();
        assert_eq!(index.stats().unwrap().total_embeddings, 1);

        index.clear().unwrap();
        assert_eq!(index.stats().unwrap().total_embeddings, 0);
    }

    #[test]
    fn test_blob_roundtrip() {
        let original: Vec<f32> = (0..512).map(|i| (i as f32) * 0.001).collect();
        let bytes = f32_slice_to_bytes(&original);
        let recovered = bytes_to_f32_slice(&bytes);
        assert_eq!(original.len(), recovered.len());
        for (a, b) in original.iter().zip(recovered.iter()) {
            assert!((a - b).abs() < 1e-10);
        }
    }

    #[test]
    fn test_search_returns_sorted_by_score() {
        let tmp = TempDir::new().unwrap();
        let mut index = VectorIndex::new(tmp.path()).unwrap();

        // Create three vectors with known similarity to a query
        let query = make_random_vector(100);
        let similar = make_random_vector(101); // should be somewhat similar (close seed)
        let different = make_random_vector(999); // should be less similar

        let entries = vec![
            VectorEntry {
                ts: 1000,
                display_id: 1,
                file_path: "a.mp4".into(),
                frame_offset_us: 0,
                vector: query.clone(), // exact match
            },
            VectorEntry {
                ts: 2000,
                display_id: 1,
                file_path: "b.mp4".into(),
                frame_offset_us: 0,
                vector: similar,
            },
            VectorEntry {
                ts: 3000,
                display_id: 1,
                file_path: "c.mp4".into(),
                frame_offset_us: 0,
                vector: different,
            },
        ];
        index.insert_entries(&entries).unwrap();

        let results = index.search(&query, 3).unwrap();
        assert_eq!(results.len(), 3);

        // First result should be the exact match
        assert_eq!(results[0].ts, 1000);
        assert!((results[0].score - 1.0).abs() < 0.01);

        // Results should be in descending score order
        for w in results.windows(2) {
            assert!(w[0].score >= w[1].score);
        }
    }

    #[test]
    fn test_vector_search_in_range_excludes_out_of_range() {
        let tmp = TempDir::new().unwrap();
        let mut index = VectorIndex::new(tmp.path()).unwrap();

        let v1 = make_random_vector(1);
        let v2 = make_random_vector(2);
        let v3 = make_random_vector(3);

        let entries = vec![
            VectorEntry {
                ts: 100,
                display_id: 1,
                file_path: "a.mp4".into(),
                frame_offset_us: 0,
                vector: v1.clone(),
            },
            VectorEntry {
                ts: 500,
                display_id: 1,
                file_path: "b.mp4".into(),
                frame_offset_us: 0,
                vector: v2.clone(),
            },
            VectorEntry {
                ts: 900,
                display_id: 1,
                file_path: "c.mp4".into(),
                frame_offset_us: 0,
                vector: v3.clone(),
            },
        ];
        index.insert_entries(&entries).unwrap();

        // Range [200, 600] should only return ts=500
        let query = make_random_vector(42);
        let results = index.search_in_range(&query, 200, 600, 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].ts, 500);
    }

    #[test]
    fn test_vector_search_in_range_empty_on_no_match() {
        let tmp = TempDir::new().unwrap();
        let mut index = VectorIndex::new(tmp.path()).unwrap();

        let entries = vec![VectorEntry {
            ts: 1000,
            display_id: 1,
            file_path: "a.mp4".into(),
            frame_offset_us: 0,
            vector: make_random_vector(1),
        }];
        index.insert_entries(&entries).unwrap();

        // Range that doesn't include any entry
        let query = make_random_vector(42);
        let results = index.search_in_range(&query, 2000, 3000, 10).unwrap();
        assert!(results.is_empty());

        // start > end → empty
        let results = index.search_in_range(&query, 3000, 1000, 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_limit_respected() {
        let tmp = TempDir::new().unwrap();
        let mut index = VectorIndex::new(tmp.path()).unwrap();

        let entries: Vec<VectorEntry> = (0..10)
            .map(|i| VectorEntry {
                ts: i * 1000,
                display_id: 1,
                file_path: format!("seg{}.mp4", i),
                frame_offset_us: 0,
                vector: make_random_vector(i),
            })
            .collect();

        index.insert_entries(&entries).unwrap();

        let results = index.search(&make_random_vector(0), 3).unwrap();
        assert_eq!(results.len(), 3);
    }
}
