mod behavioral;
mod config;
mod event;
mod retention;
pub mod search;
mod storage;
mod timeline;
pub mod vector;
mod workflow_extractor;

use std::sync::Mutex;
use std::sync::OnceLock;

use log::{error, info};
use storage::LogWriter;
use timeline::TimelineIndex;

// Proc-macro approach — no UDL file needed
uniffi::setup_scaffolding!();

// Global state — initialized once via init_storage().
// Lock ordering: always acquire STORAGE before TIMELINE before SEARCH to prevent deadlocks.
static STORAGE: OnceLock<Mutex<LogWriter>> = OnceLock::new();
static TIMELINE: OnceLock<Mutex<TimelineIndex>> = OnceLock::new();
static SEARCH: OnceLock<Mutex<search::SearchIndex>> = OnceLock::new();
static VECTOR: OnceLock<Mutex<vector::VectorIndex>> = OnceLock::new();
static DATA_PATHS: OnceLock<config::DataPaths> = OnceLock::new();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ShadowError {
    #[error("Storage error: {msg}")]
    StorageError { msg: String },
    #[error("Query error: {msg}")]
    QueryError { msg: String },
    #[error("Serialization error: {msg}")]
    SerializationError { msg: String },
    #[error("Index error: {msg}")]
    IndexError { msg: String },
}

/// Initialize the storage engine. Call once at app startup.
#[uniffi::export]
pub fn init_storage(data_dir: String) -> Result<(), ShadowError> {
    // Initialize the Rust log backend. Logs to stderr, which macOS routes to
    // unified logging for GUI apps. Filter via RUST_LOG env var (default: info).
    // Inspect with: /usr/bin/log show --predicate 'process == "Shadow"' --last 10m
    // Or in Console.app filtering by process "Shadow".
    // safe to call multiple times — subsequent calls are no-ops.
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .try_init();

    let paths = config::DataPaths::new(&data_dir);
    paths.ensure_dirs().map_err(|e| ShadowError::StorageError {
        msg: format!("Failed to create data directories: {e}"),
    })?;

    DATA_PATHS
        .set(paths.clone())
        .map_err(|_| ShadowError::StorageError {
            msg: "DataPaths already initialized".into(),
        })?;

    let writer = LogWriter::new(&paths).map_err(|e| ShadowError::StorageError {
        msg: format!("Failed to init log writer: {e}"),
    })?;

    let mut index = TimelineIndex::new(&paths).map_err(|e| ShadowError::StorageError {
        msg: format!("Failed to init timeline index: {e}"),
    })?;

    // Register the initial event segment so all events from startup are tracked
    let initial_path = writer.current_segment_path();
    let now_us = wall_micros();
    index
        .resolve_event_segment(&initial_path, now_us)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to register initial segment: {e}"),
        })?;

    // Initialize the search index (Tantivy) before moving index into TIMELINE,
    // because we may need to reset checkpoints if the search schema was rebuilt.
    let search_idx = search::SearchIndex::new(&paths.search_index).map_err(|e| {
        ShadowError::StorageError {
            msg: format!("Failed to init search index: {e}"),
        }
    })?;

    // If the search index was rebuilt (schema version change), reset all search-related
    // checkpoints so that historical data is re-indexed into the empty index.
    if search_idx.was_rebuilt() {
        info!("Search index was rebuilt — resetting search_text, ocr, and transcript checkpoints");
        index
            .set_checkpoint("search_text", 0)
            .map_err(|e| ShadowError::StorageError {
                msg: format!("Failed to reset search_text checkpoint: {e}"),
            })?;
        index
            .set_checkpoint("ocr", 0)
            .map_err(|e| ShadowError::StorageError {
                msg: format!("Failed to reset ocr checkpoint: {e}"),
            })?;
        index
            .set_checkpoint("transcript", 0)
            .map_err(|e| ShadowError::StorageError {
                msg: format!("Failed to reset transcript checkpoint: {e}"),
            })?;
    }

    // Initialize the vector index (CLIP embeddings)
    let vector_idx = vector::VectorIndex::new(&paths.vector_index).map_err(|e| {
        ShadowError::StorageError {
            msg: format!("Failed to init vector index: {e}"),
        }
    })?;

    // If the vector index was rebuilt (schema version change), reset the vector checkpoint
    if vector_idx.was_rebuilt() {
        info!("Vector index was rebuilt — resetting vector checkpoint");
        index
            .set_checkpoint("vector", 0)
            .map_err(|e| ShadowError::StorageError {
                msg: format!("Failed to reset vector checkpoint: {e}"),
            })?;
    }

    STORAGE
        .set(Mutex::new(writer))
        .map_err(|_| ShadowError::StorageError {
            msg: "Storage already initialized".into(),
        })?;

    TIMELINE
        .set(Mutex::new(index))
        .map_err(|_| ShadowError::StorageError {
            msg: "Timeline already initialized".into(),
        })?;

    SEARCH
        .set(Mutex::new(search_idx))
        .map_err(|_| ShadowError::StorageError {
            msg: "Search index already initialized".into(),
        })?;

    VECTOR
        .set(Mutex::new(vector_idx))
        .map_err(|_| ShadowError::StorageError {
            msg: "Vector index already initialized".into(),
        })?;

    info!(
        "shadow-core v{} initialized, data_dir={}",
        env!("CARGO_PKG_VERSION"),
        data_dir
    );
    Ok(())
}

fn get_data_paths() -> Result<&'static config::DataPaths, ShadowError> {
    DATA_PATHS.get().ok_or_else(|| ShadowError::StorageError {
        msg: "DataPaths not initialized".into(),
    })
}

// MARK: - Retention & Storage Management

/// Get current storage usage breakdown.
#[uniffi::export]
pub fn get_storage_usage() -> Result<retention::StorageUsage, ShadowError> {
    let paths = get_data_paths()?;
    retention::get_storage_usage(paths).map_err(|e| ShadowError::StorageError {
        msg: format!("Storage scan failed: {e}"),
    })
}

/// Plan a cleanup sweep based on current policy and disk state.
#[uniffi::export]
pub fn plan_retention_sweep() -> Result<retention::CleanupPlan, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    let policy = retention::RetentionPolicy::default();
    retention::plan_cleanup_sweep(&index.conn, &policy).map_err(|e| {
        ShadowError::StorageError { msg: e }
    })
}

/// Delete a video file. Updates the video_segments table.
#[uniffi::export]
pub fn delete_video_file(file_path: String) -> Result<u64, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    retention::delete_video_segment(&index.conn, &file_path)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Delete failed: {e}"),
        })
}

/// Delete an audio file. Updates the audio_segments table.
#[uniffi::export]
pub fn delete_audio_file(file_path: String) -> Result<u64, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    retention::delete_audio_segment(&index.conn, &file_path)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Delete failed: {e}"),
        })
}

/// Find a video segment by file path.
#[uniffi::export]
pub fn find_video_segment_by_path(
    file_path: String,
) -> Result<Option<timeline::VideoSegment>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    index.find_video_segment_by_path(&file_path).map_err(|e| {
        ShadowError::QueryError {
            msg: format!("Find video segment by path failed: {e}"),
        }
    })
}

/// Register extracted keyframes for a video segment.
/// Called by Swift after keyframe extraction succeeds. Updates tier to 'warm'.
#[uniffi::export]
pub fn register_keyframes(
    source_segment: String,
    keyframes: Vec<retention::KeyframeRecord>,
) -> Result<u32, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;
    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    let mut count = 0u32;
    let tx = index.conn.transaction().map_err(|e| ShadowError::StorageError {
        msg: format!("Transaction failed: {e}"),
    })?;
    for kf in &keyframes {
        tx.execute(
            "INSERT OR IGNORE INTO keyframes (display_id, ts, file_path, source_segment, size_bytes)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                kf.display_id,
                kf.ts as i64,
                kf.file_path,
                source_segment,
                kf.size_bytes as i64
            ],
        )
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Insert keyframe failed: {e}"),
        })?;
        count += 1;
    }
    tx.commit().map_err(|e| ShadowError::StorageError {
        msg: format!("Commit failed: {e}"),
    })?;
    // NOTE: Tier update intentionally NOT done here.
    // The Swift caller (RetentionCoordinator.finalizeKeyframes) updates the tier
    // to 'warm' only AFTER successfully deleting the source video file.
    // This prevents orphaned video files if deletion fails.
    Ok(count)
}

/// List keyframe file paths for a source segment.
#[uniffi::export]
pub fn list_keyframe_paths(source_segment: String) -> Result<Vec<String>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    index
        .list_keyframe_paths_for_segment(&source_segment)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("List keyframe paths failed: {e}"),
        })
}

/// Delete keyframe DB rows for a source segment. Call AFTER deleting files.
#[uniffi::export]
pub fn delete_keyframe_rows(source_segment: String) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    index
        .delete_keyframe_rows_for_segment(&source_segment)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Delete keyframe rows failed: {e}"),
        })?;
    Ok(())
}

/// Update a video segment's retention tier.
#[uniffi::export]
pub fn update_video_segment_tier(file_path: String, tier: String) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    index
        .update_video_segment_tier(&file_path, &tier)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Tier update failed: {e}"),
        })
}

/// Find the nearest keyframe to a timestamp for a display.
/// Used by FrameExtractor as fallback when video segment is deleted.
#[uniffi::export]
pub fn find_nearest_keyframe(
    display_id: u32,
    timestamp_us: u64,
) -> Result<Option<String>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    index
        .find_nearest_keyframe(display_id, timestamp_us)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Keyframe lookup failed: {e}"),
        })
}

/// Write a raw MessagePack event to the current log segment.
#[uniffi::export]
pub fn write_event(msgpack_data: Vec<u8>) -> Result<(), ShadowError> {
    let storage = STORAGE
        .get()
        .ok_or_else(|| ShadowError::StorageError {
            msg: "Storage not initialized".into(),
        })?;

    let mut writer = storage.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    // Parse enough to extract timestamp and track for the index
    let header = event::parse_event_header(&msgpack_data).map_err(|e| {
        ShadowError::SerializationError {
            msg: format!("Failed to parse event header: {e}"),
        }
    })?;

    // Write raw bytes to the append-only log
    writer
        .append(&msgpack_data)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Write failed: {e}"),
        })?;

    // Update the timeline index
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    // Handle rotation if it happened during append
    if let Some(rotation) = writer.take_last_rotation() {
        index
            .seal_current_event_segment(
                header.effective_ts(),
                rotation.compressed_path.as_deref(),
                rotation.compressed_path.as_ref().map(|_| "zstd"),
            )
            .map_err(|e| ShadowError::StorageError {
                msg: format!("Seal segment failed: {e}"),
            })?;
    }

    let segment_path = writer.current_segment_path();
    let segment_id = index
        .resolve_event_segment(&segment_path, header.effective_ts())
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Resolve segment failed: {e}"),
        })?;

    index
        .insert(&header, &segment_path, Some(segment_id))
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Index insert failed: {e}"),
        })?;

    Ok(())
}

/// Write a batch of raw MessagePack events. More efficient than individual writes:
/// storage appends are individual but index inserts are wrapped in one SQLite transaction.
/// Returns the number of events successfully written.
#[uniffi::export]
pub fn write_events_batch(events: Vec<Vec<u8>>) -> Result<u32, ShadowError> {
    if events.is_empty() {
        return Ok(0);
    }

    let storage = STORAGE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Storage not initialized".into(),
    })?;

    let mut writer = storage.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    // Parse headers and write to storage, tracking per-event segment paths + segment IDs
    let mut items: Vec<(event::EventHeader, String, Option<i64>)> =
        Vec::with_capacity(events.len());

    for event_data in &events {
        let header = match event::parse_event_header(event_data) {
            Ok(h) => h,
            Err(_) => continue,
        };

        writer
            .append(event_data)
            .map_err(|e| ShadowError::StorageError {
                msg: format!("Batch write failed: {e}"),
            })?;

        // Handle rotation if it happened during this append
        if let Some(rotation) = writer.take_last_rotation() {
            index
                .seal_current_event_segment(
                    header.effective_ts(),
                    rotation.compressed_path.as_deref(),
                    rotation.compressed_path.as_ref().map(|_| "zstd"),
                )
                .map_err(|e| ShadowError::StorageError {
                    msg: format!("Seal segment failed: {e}"),
                })?;
        }

        let segment_path = writer.current_segment_path();
        let segment_id = index
            .resolve_event_segment(&segment_path, header.effective_ts())
            .map_err(|e| ShadowError::StorageError {
                msg: format!("Resolve segment failed: {e}"),
            })?;

        items.push((header, segment_path, Some(segment_id)));
    }

    // Index all events in one SQLite transaction
    let refs: Vec<(&event::EventHeader, &str, Option<i64>)> = items
        .iter()
        .map(|(h, p, s)| (h, p.as_str(), *s))
        .collect();

    let batch_count = items.len();
    index.insert_batch(&refs).map_err(|e| {
        error!(
            "Batch index insert failed: {} events lost, error={}",
            batch_count, e
        );
        ShadowError::IndexError {
            msg: format!("Batch index failed: {e}"),
        }
    })?;

    Ok(batch_count as u32)
}

/// Query events in a time range. Returns structured timeline entries.
#[uniffi::export]
pub fn query_time_range(start_us: u64, end_us: u64) -> Result<Vec<timeline::TimelineEntry>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .query_range(start_us, end_us)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Query failed: {e}"),
        })
}

/// Get a summary of activity for a given day (YYYY-MM-DD format).
#[uniffi::export]
pub fn get_day_summary(date_str: String) -> Result<Vec<timeline::ActivityBlock>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .day_summary(&date_str)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Summary failed: {e}"),
        })
}

// MARK: - Video Segment Index

/// Register a new video recording segment (called when AVAssetWriter creates a file).
#[uniffi::export]
pub fn insert_video_segment(
    display_id: u32,
    start_ts: u64,
    file_path: String,
) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .insert_video_segment(display_id, start_ts, &file_path)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Insert video segment failed: {e}"),
        })
}

/// Finalize a video segment (called when AVAssetWriter finishes writing).
#[uniffi::export]
pub fn finalize_video_segment(file_path: String, end_ts: u64) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .finalize_video_segment(&file_path, end_ts)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Finalize video segment failed: {e}"),
        })
}

/// Find the video segment covering a given timestamp for a display.
#[uniffi::export]
pub fn find_video_segment(
    display_id: u32,
    timestamp_us: u64,
) -> Result<Option<timeline::VideoSegment>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .find_video_segment(display_id, timestamp_us)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Find video segment failed: {e}"),
        })
}

/// List all video segments overlapping a time range. Used by OCR worker.
#[uniffi::export]
pub fn list_video_segments(
    start_us: u64,
    end_us: u64,
) -> Result<Vec<timeline::VideoSegment>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .list_video_segments_in_range(start_us, end_us)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("List video segments failed: {e}"),
        })
}

// MARK: - Visual Change Log

/// Record a visual change distance measurement from OCRWorker.
/// Called for every 10-second sample — records distance regardless of whether OCR runs.
#[uniffi::export]
pub fn record_visual_change(
    display_id: u32,
    timestamp_us: u64,
    distance: f32,
) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    index
        .record_visual_change(display_id, timestamp_us, distance)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Visual change record failed: {e}"),
        })
}

/// Query timestamps where visual change exceeds a threshold within a time range.
/// Returns timestamps in ascending order. Used by keyframe extraction.
#[uniffi::export]
pub fn query_visual_changes(
    display_id: u32,
    start_ts: u64,
    end_ts: u64,
    min_distance: f32,
) -> Result<Vec<u64>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;
    index
        .query_visual_changes(display_id, start_ts, end_ts, min_distance)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Visual change query failed: {e}"),
        })
}

// MARK: - Audio Segment Index

/// Register a new audio recording segment.
#[uniffi::export]
pub fn insert_audio_segment(
    source: String,
    start_ts: u64,
    file_path: String,
    display_id: Option<u32>,
    sample_rate: Option<u32>,
    channels: Option<u32>,
) -> Result<i64, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .insert_audio_segment(&source, start_ts, &file_path, display_id, sample_rate, channels)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Insert audio segment failed: {e}"),
        })
}

/// Finalize an audio segment (called when recording stops or rotates).
#[uniffi::export]
pub fn finalize_audio_segment(file_path: String, end_ts: u64) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .finalize_audio_segment(&file_path, end_ts)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Finalize audio segment failed: {e}"),
        })
}

/// Find the audio segment covering a given timestamp for a source.
#[uniffi::export]
pub fn find_audio_segment(
    source: String,
    timestamp_us: u64,
) -> Result<Option<timeline::AudioSegment>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .find_audio_segment(&source, timestamp_us)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Find audio segment failed: {e}"),
        })
}

/// List sealed audio segments overlapping a time range.
/// Returns only finalized segments (end_ts > 0) — active recordings are excluded.
/// Used by the transcription worker to discover segments to process.
#[uniffi::export]
pub fn list_audio_segments(
    start_us: u64,
    end_us: u64,
) -> Result<Vec<timeline::AudioSegment>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .list_audio_segments_in_range(start_us, end_us)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("List audio segments failed: {e}"),
        })
}

/// List sealed audio segments after a checkpoint segment_id.
/// Returns segments ordered by segment_id ASC, limited to `limit` results.
/// Used by the transcription worker for skip-safe checkpoint-based pagination.
/// Use segment_id 0 to start from the beginning.
#[uniffi::export]
pub fn list_audio_segments_after_checkpoint(
    last_segment_id: i64,
    limit: u32,
) -> Result<Vec<timeline::AudioSegment>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .list_audio_segments_after_checkpoint(last_segment_id, limit)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("List audio segments after checkpoint failed: {e}"),
        })
}

/// Finalize all orphan audio segments (end_ts = 0) from a previous crash.
/// Returns the count of orphans finalized.
#[uniffi::export]
pub fn list_orphan_audio_segments() -> Result<u32, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let now = wall_micros();
    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .finalize_orphan_audio_segments(now)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Finalize orphan audio segments failed: {e}"),
        })
}

/// Run segment/index integrity check. Returns a report of consistency issues.
#[uniffi::export]
pub fn check_integrity() -> Result<timeline::IntegrityReport, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .check_segment_integrity()
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Integrity check failed: {e}"),
        })
}

/// Register a capture session in the timeline. Call at capture start.
#[uniffi::export]
pub fn register_session(session_id: String, start_ts: u64) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .register_session(&session_id, start_ts)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Register session failed: {e}"),
        })?;

    info!("Session registered: {}", session_id);
    Ok(())
}

/// Finalize a capture session. Call at capture shutdown.
#[uniffi::export]
pub fn finalize_session(session_id: String, end_ts: u64) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .finalize_session(&session_id, end_ts)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Finalize session failed: {e}"),
        })?;

    info!("Session finalized: {}", session_id);
    Ok(())
}

/// Close any open app focus interval. Call on session end or system sleep.
#[uniffi::export]
pub fn close_focus_interval(end_ts: u64) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .close_open_focus_interval(end_ts)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Close focus interval failed: {e}"),
        })
}

/// Find which app was focused at a specific timestamp.
/// Returns None if no focus interval covers that timestamp.
/// Used by OCR worker for temporally-accurate app context enrichment.
#[uniffi::export]
pub fn find_app_at_timestamp(timestamp_us: u64) -> Result<Option<timeline::AppContext>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .find_app_at_timestamp(timestamp_us)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Find app at timestamp failed: {e}"),
        })
}

/// Flush current segment and rotate to a new one.
#[uniffi::export]
pub fn flush_and_rotate() -> Result<(), ShadowError> {
    let storage = STORAGE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Storage not initialized".into(),
    })?;

    let mut writer = storage.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    writer
        .rotate()
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Rotation failed: {e}"),
        })?;

    // Update segment tracking
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    let now_us = wall_micros();

    if let Some(rotation) = writer.take_last_rotation() {
        index
            .seal_current_event_segment(
                now_us,
                rotation.compressed_path.as_deref(),
                rotation.compressed_path.as_ref().map(|_| "zstd"),
            )
            .map_err(|e| ShadowError::StorageError {
                msg: format!("Seal segment failed: {e}"),
            })?;
    }

    // Register the new segment
    let new_path = writer.current_segment_path();
    index
        .resolve_event_segment(&new_path, now_us)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Register new segment failed: {e}"),
        })?;

    info!("Segment rotated, new segment: {}", new_path);
    Ok(())
}

// MARK: - Search Index

/// Execute a text search query. Returns top `limit` results ordered by relevance.
#[uniffi::export]
pub fn search_text(query: String, limit: u32) -> Result<Vec<search::SearchResult>, ShadowError> {
    let search = SEARCH.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Search index not initialized".into(),
    })?;

    let index = search.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .search(&query, limit as usize)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Search failed: {e}"),
        })
}

/// Index events that have been captured since the last checkpoint.
/// Call periodically (e.g., every 30 seconds) to keep the search index current.
/// Returns the number of events indexed.
#[uniffi::export]
pub fn index_recent_events() -> Result<u32, ShadowError> {
    // Lock timeline first (lock ordering: TIMELINE before SEARCH)
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut tl_index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    // Read checkpoint
    let checkpoint = tl_index.get_checkpoint("search_text").map_err(|e| {
        ShadowError::QueryError {
            msg: format!("Failed to read checkpoint: {e}"),
        }
    })?;

    // Query events since checkpoint
    let now_us = wall_micros();
    let entries = tl_index.query_range(checkpoint + 1, now_us).map_err(|e| {
        ShadowError::QueryError {
            msg: format!("Failed to query events for indexing: {e}"),
        }
    })?;

    if entries.is_empty() {
        return Ok(0);
    }

    // Lock search index (while holding timeline — allowed by lock ordering)
    let search = SEARCH.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Search index not initialized".into(),
    })?;

    let mut search_idx = search.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    // Index the entries
    let count = search_idx.index_entries(&entries).map_err(|e| {
        ShadowError::StorageError {
            msg: format!("Failed to index entries: {e}"),
        }
    })?;

    // Update checkpoint to the timestamp of the last entry
    if let Some(last) = entries.last() {
        tl_index
            .set_checkpoint("search_text", last.ts)
            .map_err(|e| ShadowError::StorageError {
                msg: format!("Failed to update checkpoint: {e}"),
            })?;
    }

    Ok(count)
}

/// Index a batch of OCR text entries into the search index.
/// Called by the Swift OCR worker after processing video frames.
/// Returns the number of entries indexed.
#[uniffi::export]
pub fn index_ocr_text(entries: Vec<search::OcrEntry>) -> Result<u32, ShadowError> {
    if entries.is_empty() {
        return Ok(0);
    }

    let search = SEARCH.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Search index not initialized".into(),
    })?;

    let mut search_idx = search.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    search_idx.index_ocr_entries(&entries).map_err(|e| {
        ShadowError::StorageError {
            msg: format!("Failed to index OCR entries: {e}"),
        }
    })
}

/// Index a batch of transcript chunk entries into the search index.
/// Called by the Swift transcription worker after processing audio segments.
/// Returns the number of entries indexed.
#[uniffi::export]
pub fn index_transcript_text(entries: Vec<search::TranscriptEntry>) -> Result<u32, ShadowError> {
    if entries.is_empty() {
        return Ok(0);
    }

    let search = SEARCH.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Search index not initialized".into(),
    })?;

    let mut search_idx = search.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    search_idx.index_transcript_entries(&entries).map_err(|e| {
        ShadowError::StorageError {
            msg: format!("Failed to index transcript entries: {e}"),
        }
    })
}

/// List transcript chunks within a time range, with pagination.
/// Returns up to `limit` results starting at `offset`, sorted by ts_start ascending.
/// Used by the meeting summarization pipeline to retrieve all transcript text
/// within a time window without loading the entire index into memory.
#[uniffi::export]
pub fn list_transcript_chunks_in_range(
    start_us: u64,
    end_us: u64,
    limit: u32,
    offset: u32,
) -> Result<Vec<search::TranscriptChunkResult>, ShadowError> {
    let search = SEARCH.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Search index not initialized".into(),
    })?;

    let index = search.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .list_transcript_chunks_in_range(start_us, end_us, limit, offset)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("List transcript chunks failed: {e}"),
        })
}

/// Get the last checkpoint timestamp for a named index.
/// Used by Swift workers to determine where to resume processing.
#[uniffi::export]
pub fn get_index_checkpoint(index_name: String) -> Result<u64, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .get_checkpoint(&index_name)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Failed to read checkpoint: {e}"),
        })
}

/// Set the checkpoint timestamp for a named index.
/// Used by Swift workers to persist progress.
#[uniffi::export]
pub fn set_index_checkpoint(index_name: String, last_ts: u64) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let mut index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .set_checkpoint(&index_name, last_ts)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to set checkpoint: {e}"),
        })
}

// MARK: - Vector Index

/// Insert a batch of vector embeddings into the vector index.
/// Called by the Swift embedding worker after processing video frames.
/// Returns the number of entries indexed.
#[uniffi::export]
pub fn insert_vector_entries(
    entries: Vec<vector::VectorEntry>,
) -> Result<u32, ShadowError> {
    if entries.is_empty() {
        return Ok(0);
    }

    let vector = VECTOR.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Vector index not initialized".into(),
    })?;

    let mut vec_idx = vector.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    vec_idx.insert_entries(&entries).map_err(|e| {
        ShadowError::StorageError {
            msg: format!("Failed to index vector entries: {e}"),
        }
    })
}

/// Search the vector index with a query vector.
/// Returns the top `limit` results sorted by cosine similarity.
#[uniffi::export]
pub fn search_vector(
    query_vector: Vec<f32>,
    limit: u32,
) -> Result<Vec<vector::VectorSearchResult>, ShadowError> {
    let vector = VECTOR.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Vector index not initialized".into(),
    })?;

    let vec_idx = vector.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    vec_idx
        .search(&query_vector, limit as usize)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Vector search failed: {e}"),
        })
}

/// Execute a hybrid search combining text and vector retrieval.
/// If `query_vector` is provided, merges text results with vector results.
/// If `query_vector` is empty, behaves identically to `search_text`.
/// Returns deduplicated results sorted by relevance.
#[uniffi::export]
pub fn search_hybrid(
    query: String,
    query_vector: Vec<f32>,
    limit: u32,
) -> Result<Vec<search::SearchResult>, ShadowError> {
    // Text search (always)
    let text_results = search_text(query.clone(), limit)?;

    // Vector search (only if query_vector is non-empty)
    if query_vector.is_empty() {
        return Ok(text_results);
    }

    let vector = VECTOR.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Vector index not initialized".into(),
    })?;

    let vec_idx = vector.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    let vector_results = vec_idx
        .search(&query_vector, limit as usize)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Vector search failed: {e}"),
        })?;

    if vector_results.is_empty() {
        return Ok(text_results);
    }

    // Look up app context for vector results and convert to SearchResult format
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;
    let tl_index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    // Normalize text scores to [0, 1] for fair comparison
    let max_text_score = text_results
        .iter()
        .map(|r| r.score)
        .fold(0.0f32, f32::max);
    let text_norm = if max_text_score > 0.0 {
        max_text_score
    } else {
        1.0
    };

    let mut all_results: Vec<search::SearchResult> = text_results
        .into_iter()
        .map(|mut r| {
            r.score /= text_norm; // Normalize to [0, 1]
            r
        })
        .collect();

    // Convert vector results to SearchResult format
    for vr in &vector_results {
        let app_ctx = tl_index.find_app_at_timestamp(vr.ts).ok().flatten();
        let app_name = app_ctx
            .as_ref()
            .map(|c| c.app_name.clone())
            .unwrap_or_default();

        all_results.push(search::SearchResult {
            ts: vr.ts,
            app_name,
            window_title: String::new(),
            url: String::new(),
            display_id: Some(vr.display_id),
            event_type: String::new(),
            score: vr.score, // Cosine similarity already in [0, 1] for normalized vectors
            match_reason: "visual".to_string(),
            source_kind: "visual".to_string(),
            snippet: String::new(),
            audio_segment_id: None,
            audio_source: String::new(),
            ts_end: 0,
            confidence: None,
        });
    }

    // Sort by score descending (all normalized to ~[0, 1])
    all_results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));

    // Dedup using existing logic
    let deduped = search::deduplicate_results_public(all_results, limit as usize);

    Ok(deduped)
}

/// Search the vector index within a timestamp range.
/// Returns the top `limit` results where `ts_wall_us` is between `start_us` and `end_us`.
#[uniffi::export]
pub fn search_vector_in_range(
    query_vector: Vec<f32>,
    start_us: u64,
    end_us: u64,
    limit: u32,
) -> Result<Vec<vector::VectorSearchResult>, ShadowError> {
    let vector = VECTOR.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Vector index not initialized".into(),
    })?;

    let vec_idx = vector.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    vec_idx
        .search_in_range(&query_vector, start_us, end_us, limit as usize)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Vector range search failed: {e}"),
        })
}

/// Execute a hybrid search within a timestamp range.
/// Combines text search (Tantivy) with vector search (CLIP), both filtered to [start_us, end_us].
/// If `query_vector` is empty, only text search is performed.
/// Returns deduplicated results sorted by relevance.
#[uniffi::export]
pub fn search_hybrid_in_range(
    query: String,
    query_vector: Vec<f32>,
    start_us: u64,
    end_us: u64,
    limit: u32,
) -> Result<Vec<search::SearchResult>, ShadowError> {
    // Text search within range
    let search = SEARCH.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Search index not initialized".into(),
    })?;

    let search_idx = search.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    let text_results = search_idx
        .search_in_range(&query, start_us, end_us, limit as usize)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Text range search failed: {e}"),
        })?;

    drop(search_idx); // Release lock before acquiring vector lock

    // Vector search within range (only if query_vector is non-empty)
    if query_vector.is_empty() {
        return Ok(text_results);
    }

    let vector = VECTOR.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Vector index not initialized".into(),
    })?;

    let vec_idx = vector.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    let vector_results = vec_idx
        .search_in_range(&query_vector, start_us, end_us, limit as usize)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Vector range search failed: {e}"),
        })?;

    drop(vec_idx);

    if vector_results.is_empty() {
        return Ok(text_results);
    }

    // Look up app context for vector results
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;
    let tl_index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    // Normalize text scores to [0, 1]
    let max_text_score = text_results
        .iter()
        .map(|r| r.score)
        .fold(0.0f32, f32::max);
    let text_norm = if max_text_score > 0.0 {
        max_text_score
    } else {
        1.0
    };

    let mut all_results: Vec<search::SearchResult> = text_results
        .into_iter()
        .map(|mut r| {
            r.score /= text_norm;
            r
        })
        .collect();

    for vr in &vector_results {
        let app_ctx = tl_index.find_app_at_timestamp(vr.ts).ok().flatten();
        let app_name = app_ctx
            .as_ref()
            .map(|c| c.app_name.clone())
            .unwrap_or_default();

        all_results.push(search::SearchResult {
            ts: vr.ts,
            app_name,
            window_title: String::new(),
            url: String::new(),
            display_id: Some(vr.display_id),
            event_type: String::new(),
            score: vr.score,
            match_reason: "visual".to_string(),
            source_kind: "visual".to_string(),
            snippet: String::new(),
            audio_segment_id: None,
            audio_source: String::new(),
            ts_end: 0,
            confidence: None,
        });
    }

    all_results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));

    let deduped = search::deduplicate_results_public(all_results, limit as usize);
    Ok(deduped)
}

/// Get vector index statistics for diagnostics.
#[uniffi::export]
pub fn get_vector_index_stats() -> Result<vector::VectorIndexStats, ShadowError> {
    let vector = VECTOR.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Vector index not initialized".into(),
    })?;

    let vec_idx = vector.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    vec_idx.stats().map_err(|e| ShadowError::QueryError {
        msg: format!("Vector index stats failed: {e}"),
    })
}

/// Get search index statistics for diagnostics.
#[uniffi::export]
pub fn get_search_index_stats() -> Result<search::SearchIndexStats, ShadowError> {
    let search = SEARCH.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Search index not initialized".into(),
    })?;

    let index = search.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    Ok(index.stats())
}

// MARK: - AX Snapshots (Agent System Phase 1)

/// Insert an AX tree snapshot record into the timeline index.
#[uniffi::export]
pub fn insert_ax_snapshot(
    timestamp_us: u64,
    app_bundle_id: String,
    app_name: String,
    window_title: Option<String>,
    display_id: Option<u32>,
    tree_hash: u64,
    node_count: u32,
    trigger: Option<String>,
) -> Result<i64, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .insert_ax_snapshot(
            timestamp_us,
            &app_bundle_id,
            &app_name,
            window_title.as_deref(),
            display_id,
            tree_hash,
            node_count,
            trigger.as_deref(),
        )
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to insert AX snapshot: {e}"),
        })
}

/// Find an AX snapshot by approximate timestamp.
#[uniffi::export]
pub fn find_ax_snapshot(timestamp_us: u64) -> Result<Option<timeline::AxSnapshotRecord>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .find_ax_snapshot(timestamp_us)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Failed to find AX snapshot: {e}"),
        })
}

/// Query AX snapshots for an app within a time range.
#[uniffi::export]
pub fn query_ax_snapshots(
    app_bundle_id: Option<String>,
    start_ts: u64,
    end_ts: u64,
    limit: u32,
) -> Result<Vec<timeline::AxSnapshotRecord>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .query_ax_snapshots(
            app_bundle_id.as_deref(),
            start_ts,
            end_ts,
            limit,
        )
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Failed to query AX snapshots: {e}"),
        })
}

// MARK: - Procedure CRUD (Phase 3)

/// Insert or replace a procedure record in the SQLite index.
#[uniffi::export]
pub fn insert_procedure(
    id: String,
    name: String,
    description: String,
    source_app: String,
    source_bundle_id: String,
    step_count: u32,
    parameter_count: u32,
    tags: String,
    created_at: u64,
    updated_at: u64,
) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .insert_procedure(
            &id,
            &name,
            &description,
            &source_app,
            &source_bundle_id,
            step_count,
            parameter_count,
            &tags,
            created_at,
            updated_at,
        )
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to insert procedure: {e}"),
        })
}

/// Query procedures, optionally filtering by source app.
#[uniffi::export]
pub fn query_procedures(
    source_app: Option<String>,
    limit: u32,
) -> Result<Vec<timeline::ProcedureRecord>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .query_procedures(source_app.as_deref(), limit)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Failed to query procedures: {e}"),
        })
}

/// Delete a procedure by ID.
#[uniffi::export]
pub fn delete_procedure(id: String) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .delete_procedure(&id)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to delete procedure: {e}"),
        })
}

// --- Semantic Knowledge UniFFI Exports (Phase 5) ---

/// Insert or replace a semantic knowledge record.
#[uniffi::export]
pub fn upsert_semantic_knowledge(
    id: String,
    category: String,
    key: String,
    value: String,
    confidence: f64,
    source_episode_ids: String,
    created_at: u64,
    updated_at: u64,
) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .upsert_semantic_knowledge(
            &id, &category, &key, &value, confidence, &source_episode_ids, created_at, updated_at,
        )
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to upsert semantic knowledge: {e}"),
        })
}

/// Query semantic knowledge, optionally filtered by category.
#[uniffi::export]
pub fn query_semantic_knowledge(
    category: Option<String>,
    limit: u32,
) -> Result<Vec<timeline::SemanticKnowledgeRecord>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .query_semantic_knowledge(category.as_deref(), limit)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Failed to query semantic knowledge: {e}"),
        })
}

/// Record an access to a semantic knowledge record (increments access_count).
#[uniffi::export]
pub fn touch_semantic_knowledge(id: String, now_us: u64) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .touch_semantic_knowledge(&id, now_us)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to touch semantic knowledge: {e}"),
        })
}

/// Delete a semantic knowledge record by ID.
#[uniffi::export]
pub fn delete_semantic_knowledge(id: String) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .delete_semantic_knowledge(&id)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to delete semantic knowledge: {e}"),
        })
}

// --- Directive UniFFI Exports (Phase 5) ---

/// Insert or replace a directive.
#[uniffi::export]
pub fn upsert_directive(
    id: String,
    directive_type: String,
    trigger_pattern: String,
    action_description: String,
    priority: i32,
    created_at: u64,
    expires_at: Option<u64>,
    source_context: String,
) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .upsert_directive(
            &id,
            &directive_type,
            &trigger_pattern,
            &action_description,
            priority,
            created_at,
            expires_at,
            &source_context,
        )
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to upsert directive: {e}"),
        })
}

/// Query active directives (non-expired, is_active=1).
#[uniffi::export]
pub fn query_active_directives(
    now_us: u64,
    limit: u32,
) -> Result<Vec<timeline::DirectiveRecord>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .query_active_directives(now_us, limit)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Failed to query active directives: {e}"),
        })
}

/// Record that a directive was triggered.
#[uniffi::export]
pub fn record_directive_trigger(id: String, now_us: u64) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .record_directive_trigger(&id, now_us)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to record directive trigger: {e}"),
        })
}

/// Deactivate a directive (set is_active=0).
#[uniffi::export]
pub fn deactivate_directive(id: String) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .deactivate_directive(&id)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to deactivate directive: {e}"),
        })
}

/// Delete a directive by ID.
#[uniffi::export]
pub fn delete_directive(id: String) -> Result<(), ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::StorageError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::StorageError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    index
        .delete_directive(&id)
        .map_err(|e| ShadowError::StorageError {
            msg: format!("Failed to delete directive: {e}"),
        })
}

/// MARK: - Behavioral Search (Mimicry Phase A)

/// Search for past interaction sequences matching an app and query.
/// Returns sequences of user actions (clicks, keystrokes) with AX context,
/// grouped by temporal proximity. Used to inject behavioral memory into the agent prompt.
#[uniffi::export]
pub fn search_behavioral_context(
    query: String,
    target_app: String,
    max_results: u32,
) -> Result<Vec<behavioral::BehavioralSequence>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    behavioral::search_behavioral_context(&index.conn, &query, &target_app, max_results)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Behavioral search failed: {e}"),
        })
}

/// Count AX-enriched mouse_down events in a time range.
/// Used by diagnostics to track how much enriched data has been collected.
#[uniffi::export]
pub fn count_enriched_clicks(start_us: u64, end_us: u64) -> Result<u64, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    behavioral::count_enriched_clicks(&index.conn, start_us, end_us).map_err(|e| {
        ShadowError::QueryError {
            msg: format!("Count query failed: {e}"),
        }
    })
}

/// Find the most frequently interacted AX elements for an app.
/// Returns (role, title, count) tuples. Used for building app interaction profiles.
#[uniffi::export]
pub fn top_app_interactions(
    app_name: String,
    limit: u32,
) -> Result<Vec<behavioral::InteractionSummary>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;

    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    behavioral::top_interactions(&index.conn, &app_name, limit)
        .map(|tuples| {
            tuples
                .into_iter()
                .map(|(role, title, count)| behavioral::InteractionSummary {
                    ax_role: role,
                    ax_title: title,
                    count,
                })
                .collect()
        })
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Top interactions query failed: {e}"),
        })
}

/// MARK: - Workflow Extraction (Mimicry Phase A4)

/// Extract recurring workflow patterns from passively recorded user behavior.
/// Scans enriched events within the lookback window and finds action sequences
/// that repeat across sessions. Returns AX-anchored workflows sorted by confidence.
#[uniffi::export]
pub fn extract_workflows(
    lookback_hours: u32,
    max_results: u32,
) -> Result<Vec<workflow_extractor::ExtractedWorkflow>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    workflow_extractor::extract_workflows(&index.conn, lookback_hours, max_results)
        .map_err(|e| ShadowError::QueryError {
            msg: format!("Workflow extraction failed: {e}"),
        })
}

/// Extract recurring workflow patterns for a specific app.
#[uniffi::export]
pub fn extract_workflows_for_app(
    app_name: String,
    lookback_hours: u32,
    max_results: u32,
) -> Result<Vec<workflow_extractor::ExtractedWorkflow>, ShadowError> {
    let timeline = TIMELINE.get().ok_or_else(|| ShadowError::QueryError {
        msg: "Timeline not initialized".into(),
    })?;
    let index = timeline.lock().map_err(|e| ShadowError::QueryError {
        msg: format!("Lock poisoned: {e}"),
    })?;

    workflow_extractor::extract_workflows_for_app(
        &index.conn,
        &app_name,
        lookback_hours,
        max_results,
    )
    .map_err(|e| ShadowError::QueryError {
        msg: format!("App workflow extraction failed: {e}"),
    })
}

/// Return the core library version (useful for verifying the bridge works).
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Current wall clock in Unix microseconds.
fn wall_micros() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
}
