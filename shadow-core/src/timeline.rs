use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::config::DataPaths;
use crate::event::EventHeader;

/// Lightweight SQLite index for time-range queries.
/// NOT the primary data store — just an index over the event log.
pub struct TimelineIndex {
    pub(crate) conn: Connection,
    /// Cached (segment_id, path) for the current open event segment.
    /// Avoids repeated SQLite queries on the hot path.
    event_segment_cache: Option<(i64, String)>,
}

/// A row from the timeline index, returned by queries.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct TimelineEntry {
    pub ts: u64,
    pub track: u8,
    pub event_type: String,
    pub app_name: Option<String>,
    pub window_title: Option<String>,
    pub url: Option<String>,
    pub display_id: Option<u32>,
    pub segment_file: String,
}

/// Summary of activity in a time block (for the colored timeline bar).
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ActivityBlock {
    pub start_ts: u64,
    pub end_ts: u64,
    pub app_name: String,
    pub event_count: u32,
}

/// A video recording segment — maps a time range to an MP4 file.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct VideoSegment {
    pub display_id: u32,
    pub start_ts: u64,
    pub end_ts: u64,
    pub file_path: String,
}

/// An audio recording segment — maps a time range to an audio file.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct AudioSegment {
    pub segment_id: i64,
    pub source: String,
    pub start_ts: u64,
    pub end_ts: u64,
    pub file_path: String,
    pub display_id: Option<u32>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u32>,
}

/// App context at a point in time, derived from app_focus_intervals.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct AppContext {
    pub app_name: String,
    pub bundle_id: Option<String>,
}

/// A sealed segment path with its status, for file existence checking.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct SegmentPathEntry {
    pub path: String,
    pub status: String,
}

/// An AX tree snapshot record from the ax_snapshots table.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct AxSnapshotRecord {
    pub id: i64,
    pub timestamp_us: u64,
    pub app_bundle_id: String,
    pub app_name: String,
    pub window_title: Option<String>,
    pub display_id: Option<u32>,
    pub tree_hash: u64,
    pub node_count: u32,
    pub trigger: Option<String>,
}

/// A procedure record from the procedures table.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ProcedureRecord {
    pub id: String,
    pub name: String,
    pub description: String,
    pub source_app: String,
    pub source_bundle_id: String,
    pub step_count: u32,
    pub parameter_count: u32,
    pub tags: String,
    pub created_at: u64,
    pub updated_at: u64,
}

/// A semantic knowledge record from the semantic_knowledge table.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct SemanticKnowledgeRecord {
    pub id: String,
    pub category: String,
    pub key: String,
    pub value: String,
    pub confidence: f64,
    pub source_episode_ids: String,
    pub created_at: u64,
    pub updated_at: u64,
    pub access_count: u32,
    pub last_accessed_at: Option<u64>,
}

/// A directive record from the directives table.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct DirectiveRecord {
    pub id: String,
    pub directive_type: String,
    pub trigger_pattern: String,
    pub action_description: String,
    pub priority: i32,
    pub created_at: u64,
    pub expires_at: Option<u64>,
    pub is_active: bool,
    pub execution_count: u32,
    pub last_triggered_at: Option<u64>,
    pub source_context: String,
}

/// Result of segment/index integrity check.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct IntegrityReport {
    pub stale_segment_refs: u64,
    pub total_events: u64,
    pub events_with_segment_id: u64,
    pub segments_count: u64,
    pub video_segments_count: u64,
    pub audio_segments_count: u64,
    pub ordering_violations: u64,
    /// Sealed segment paths — caller checks file existence.
    pub sealed_segment_paths: Vec<SegmentPathEntry>,
}

impl TimelineIndex {
    pub fn new(paths: &DataPaths) -> Result<Self, rusqlite::Error> {
        let conn = Connection::open(&paths.timeline_db)?;

        // WAL mode for better concurrent read/write performance
        conn.pragma_update(None, "journal_mode", "WAL")?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS events_index (
                ts           INTEGER NOT NULL,
                track        INTEGER NOT NULL,
                event_type   TEXT NOT NULL DEFAULT '',
                app_name     TEXT,
                window_title TEXT,
                url          TEXT,
                segment_file TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_ts ON events_index(ts);
            CREATE INDEX IF NOT EXISTS idx_app ON events_index(app_name);
            CREATE INDEX IF NOT EXISTS idx_track ON events_index(track);

            CREATE TABLE IF NOT EXISTS video_segments (
                display_id   INTEGER NOT NULL,
                start_ts     INTEGER NOT NULL,
                end_ts       INTEGER NOT NULL DEFAULT 0,
                file_path    TEXT NOT NULL UNIQUE
            );
            CREATE INDEX IF NOT EXISTS idx_video_display_start
                ON video_segments(display_id, start_ts);

            -- Unified segments table (events, video, audio)
            CREATE TABLE IF NOT EXISTS segments (
                segment_id  INTEGER PRIMARY KEY,
                kind        TEXT NOT NULL,
                start_ts    INTEGER NOT NULL,
                end_ts      INTEGER NOT NULL DEFAULT 0,
                path        TEXT NOT NULL,
                compression TEXT,
                status      TEXT NOT NULL DEFAULT 'open'
            );
            CREATE INDEX IF NOT EXISTS idx_segments_kind_start
                ON segments(kind, start_ts);

            -- Capture session tracking
            CREATE TABLE IF NOT EXISTS capture_sessions (
                session_id  TEXT PRIMARY KEY,
                start_ts    INTEGER NOT NULL,
                end_ts      INTEGER NOT NULL DEFAULT 0,
                status      TEXT NOT NULL DEFAULT 'active'
            );

            -- Audio recording segments (Track 4).
            -- Mirrors the video_segments pattern for audio files.
            CREATE TABLE IF NOT EXISTS audio_segments (
                segment_id  INTEGER PRIMARY KEY,
                source      TEXT NOT NULL,
                start_ts    INTEGER NOT NULL,
                end_ts      INTEGER NOT NULL DEFAULT 0,
                file_path   TEXT NOT NULL UNIQUE,
                display_id  INTEGER,
                sample_rate INTEGER,
                channels    INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_audio_source_start
                ON audio_segments(source, start_ts);

            -- Index checkpoints: tracks last-indexed timestamp per background index.
            -- Restart-safe: survives app restart, each index type has independent checkpoint.
            CREATE TABLE IF NOT EXISTS index_checkpoints (
                index_name TEXT PRIMARY KEY,
                last_ts    INTEGER NOT NULL DEFAULT 0
            );

            -- App focus intervals derived from Track 3 transitions.
            -- Each row represents a continuous period where an app was in the foreground.
            CREATE TABLE IF NOT EXISTS app_focus_intervals (
                id          INTEGER PRIMARY KEY,
                app_name    TEXT NOT NULL,
                bundle_id   TEXT,
                start_ts    INTEGER NOT NULL,
                end_ts      INTEGER NOT NULL DEFAULT 0,
                display_id  INTEGER,
                session_id  TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_focus_start
                ON app_focus_intervals(start_ts);
            CREATE INDEX IF NOT EXISTS idx_focus_app
                ON app_focus_intervals(app_name, start_ts);

            -- Visual change distances recorded by OCRWorker every 10s sample.
            -- Enables future keyframe extraction at visual change points without re-scanning video.
            CREATE TABLE IF NOT EXISTS visual_change_log (
                display_id   INTEGER NOT NULL,
                timestamp_us INTEGER NOT NULL,
                distance     REAL NOT NULL,
                PRIMARY KEY (display_id, timestamp_us)
            );

            -- Keyframes extracted from video segments during warm tier processing.
            CREATE TABLE IF NOT EXISTS keyframes (
                id              INTEGER PRIMARY KEY,
                display_id      INTEGER NOT NULL,
                ts              INTEGER NOT NULL,
                file_path       TEXT NOT NULL UNIQUE,
                source_segment  TEXT NOT NULL,
                size_bytes      INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_keyframes_display_ts
                ON keyframes(display_id, ts);

            -- Retention policy persisted as key-value pairs.
            CREATE TABLE IF NOT EXISTS retention_config (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );",
        )?;

        // Migrate events_index: add v2 columns (idempotent — ignores duplicate column errors)
        for &(col, col_type) in &[
            ("seq", "INTEGER"),
            ("session_id", "TEXT"),
            ("display_id", "INTEGER"),
            ("pid", "INTEGER"),
            ("bundle_id", "TEXT"),
            ("segment_id", "INTEGER"),
            // Mimicry Phase A1: AX enrichment columns for mouse_down events
            ("ax_role", "TEXT"),
            ("ax_title", "TEXT"),
            ("ax_identifier", "TEXT"),
            // Mimicry: click coordinates for training data generation
            ("click_x", "INTEGER"),
            ("click_y", "INTEGER"),
        ] {
            let sql = format!(
                "ALTER TABLE events_index ADD COLUMN {} {}",
                col, col_type
            );
            let _ = conn.execute_batch(&sql);
        }

        // Mimicry Phase A1: index on ax_role for behavioral queries
        let _ = conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_ax_role ON events_index(ax_role);
             CREATE INDEX IF NOT EXISTS idx_ax_title ON events_index(ax_title);",
        );

        // video_segments retention columns
        for &(col, col_type) in &[
            ("retention_tier", "TEXT DEFAULT 'hot'"),
            ("deleted_at", "INTEGER"),
        ] {
            let sql = format!(
                "ALTER TABLE video_segments ADD COLUMN {} {}",
                col, col_type
            );
            let _ = conn.execute_batch(&sql);
        }

        // audio_segments retention columns
        for &(col, col_type) in &[
            ("retention_tier", "TEXT DEFAULT 'hot'"),
            ("deleted_at", "INTEGER"),
        ] {
            let sql = format!(
                "ALTER TABLE audio_segments ADD COLUMN {} {}",
                col, col_type
            );
            let _ = conn.execute_batch(&sql);
        }

        // AX snapshots table for the agent system (Phase 1)
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS ax_snapshots (
                id              INTEGER PRIMARY KEY,
                timestamp_us    INTEGER NOT NULL,
                app_bundle_id   TEXT NOT NULL,
                app_name        TEXT NOT NULL,
                window_title    TEXT,
                display_id      INTEGER,
                tree_hash       INTEGER NOT NULL,
                node_count      INTEGER NOT NULL,
                trigger         TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_ax_snap_ts
                ON ax_snapshots(timestamp_us);
            CREATE INDEX IF NOT EXISTS idx_ax_snap_app
                ON ax_snapshots(app_bundle_id, timestamp_us);
            CREATE INDEX IF NOT EXISTS idx_ax_snap_hash
                ON ax_snapshots(tree_hash);",
        )?;

        // Procedures table for the agent system (Phase 3)
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS procedures (
                id                  TEXT PRIMARY KEY,
                name                TEXT NOT NULL,
                description         TEXT NOT NULL DEFAULT '',
                source_app          TEXT NOT NULL,
                source_bundle_id    TEXT NOT NULL DEFAULT '',
                step_count          INTEGER NOT NULL DEFAULT 0,
                parameter_count     INTEGER NOT NULL DEFAULT 0,
                tags                TEXT NOT NULL DEFAULT '',
                created_at          INTEGER NOT NULL,
                updated_at          INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_proc_app
                ON procedures(source_app);
            CREATE INDEX IF NOT EXISTS idx_proc_updated
                ON procedures(updated_at);",
        )?;

        // Semantic knowledge table (Phase 5)
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS semantic_knowledge (
                id                  TEXT PRIMARY KEY,
                category            TEXT NOT NULL,
                key                 TEXT NOT NULL,
                value               TEXT NOT NULL,
                confidence          REAL NOT NULL DEFAULT 1.0,
                source_episode_ids  TEXT NOT NULL DEFAULT '',
                created_at          INTEGER NOT NULL,
                updated_at          INTEGER NOT NULL,
                access_count        INTEGER NOT NULL DEFAULT 0,
                last_accessed_at    INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_sk_category
                ON semantic_knowledge(category);
            CREATE INDEX IF NOT EXISTS idx_sk_key
                ON semantic_knowledge(key);
            CREATE INDEX IF NOT EXISTS idx_sk_updated
                ON semantic_knowledge(updated_at);",
        )?;

        // Directives table (Phase 5)
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS directives (
                id                  TEXT PRIMARY KEY,
                directive_type      TEXT NOT NULL,
                trigger_pattern     TEXT NOT NULL,
                action_description  TEXT NOT NULL,
                priority            INTEGER NOT NULL DEFAULT 0,
                created_at          INTEGER NOT NULL,
                expires_at          INTEGER,
                is_active           INTEGER NOT NULL DEFAULT 1,
                execution_count     INTEGER NOT NULL DEFAULT 0,
                last_triggered_at   INTEGER,
                source_context      TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_dir_active
                ON directives(is_active, expires_at);
            CREATE INDEX IF NOT EXISTS idx_dir_type
                ON directives(directive_type);",
        )?;

        Ok(Self {
            conn,
            event_segment_cache: None,
        })
    }

    /// Insert an event header into the index.
    /// Populates v2 columns when present; leaves them NULL for v1 events.
    /// Automatically records app focus intervals for app_switch events.
    pub fn insert(
        &mut self,
        header: &EventHeader,
        segment_file: &str,
        segment_id: Option<i64>,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO events_index
                (ts, track, event_type, app_name, window_title, url, segment_file,
                 seq, session_id, display_id, pid, bundle_id, segment_id,
                 ax_role, ax_title, ax_identifier, click_x, click_y)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
            params![
                header.effective_ts() as i64,
                header.track,
                header.r#type.as_deref().unwrap_or(""),
                header.app_name,
                header.window_title,
                header.url,
                segment_file,
                header.seq.map(|s| s as i64),
                header.session_id,
                header.display_id,
                header.pid,
                header.bundle_id,
                segment_id,
                header.ax_role,
                header.ax_title,
                header.ax_identifier,
                header.click_x,
                header.click_y,
            ],
        )?;

        // Track app focus intervals for app_switch events
        if header.r#type.as_deref() == Some("app_switch") {
            if let Some(ref app_name) = header.app_name {
                self.record_app_focus(
                    app_name,
                    header.bundle_id.as_deref(),
                    header.effective_ts(),
                    header.display_id,
                    header.session_id.as_deref(),
                )?;
            }
        }

        Ok(())
    }

    /// Query all indexed events in a time range.
    /// Resolves segment paths through the `segments` table when `segment_id` is present,
    /// falling back to the raw `segment_file` for legacy rows without `segment_id`.
    /// This ensures paths remain valid after compression/rotation.
    pub fn query_range(
        &self,
        start_us: u64,
        end_us: u64,
    ) -> Result<Vec<TimelineEntry>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT e.ts, e.track, e.event_type, e.app_name, e.window_title, e.url,
                    COALESCE(s.path, e.segment_file) as resolved_path,
                    e.display_id
             FROM events_index e
             LEFT JOIN segments s ON e.segment_id = s.segment_id
             WHERE e.ts >= ?1 AND e.ts <= ?2
             ORDER BY e.ts ASC",
        )?;

        let rows = stmt.query_map(params![start_us as i64, end_us as i64], |row| {
            Ok(TimelineEntry {
                ts: row.get::<_, i64>(0)? as u64,
                track: row.get::<_, u8>(1)?,
                event_type: row.get(2)?,
                app_name: row.get(3)?,
                window_title: row.get(4)?,
                url: row.get(5)?,
                display_id: row.get::<_, Option<i64>>(7)?.map(|v| v as u32),
                segment_file: row.get(6)?,
            })
        })?;

        rows.collect()
    }

    /// Get a summary of app usage for a given day, based on actual focus intervals.
    /// Returns occupancy-based blocks (how long each app was in the foreground),
    /// not event-count-based blocks.
    ///
    /// Falls back to event-count-based summary if no focus intervals exist
    /// (for backward compatibility with data recorded before Phase E).
    pub fn day_summary(&self, date_str: &str) -> Result<Vec<ActivityBlock>, rusqlite::Error> {
        let (start, end) = Self::date_to_micros(date_str)?;

        // Try occupancy-based summary first
        let intervals = self.query_focus_intervals(start, end)?;
        if !intervals.is_empty() {
            return Ok(intervals);
        }

        // Fallback: event-count-based summary for legacy data
        self.day_summary_event_density(start, end)
    }

    /// Convert a date string to (start_us, end_us) in Unix microseconds.
    /// Each boundary resolves with its own UTC offset to handle DST transitions.
    fn date_to_micros(date_str: &str) -> Result<(u64, u64), rusqlite::Error> {
        let date = chrono::NaiveDate::parse_from_str(date_str, "%Y-%m-%d")
            .map_err(|e| rusqlite::Error::InvalidParameterName(format!("Bad date: {e}")))?;

        let start_naive = date.and_hms_opt(0, 0, 0).expect("midnight is always valid");
        let start_us = Self::resolve_local_micros(start_naive, date_str)?;

        let end_naive = date
            .and_hms_opt(23, 59, 59)
            .expect("23:59:59 is always valid");
        let end_us = Self::resolve_local_micros(end_naive, date_str)?;

        Ok((start_us, end_us))
    }

    /// Resolve a naive local datetime to UTC microseconds, handling DST.
    /// - Single: normal case.
    /// - Ambiguous (fall-back): use the earlier (pre-transition) interpretation.
    /// - None (spring-forward gap): use noon's offset as a safe fallback.
    fn resolve_local_micros(
        naive: chrono::NaiveDateTime,
        date_str: &str,
    ) -> Result<u64, rusqlite::Error> {
        let ts_micros = match naive.and_local_timezone(chrono::Local) {
            chrono::LocalResult::Single(dt) => dt.timestamp_micros(),
            chrono::LocalResult::Ambiguous(dt, _) => dt.timestamp_micros(),
            chrono::LocalResult::None => {
                // Time doesn't exist (spring-forward gap). Fall back to noon offset.
                let noon = naive.date().and_hms_opt(12, 0, 0).unwrap();
                let offset_secs = match noon.and_local_timezone(chrono::Local) {
                    chrono::LocalResult::Single(dt) => dt.offset().local_minus_utc(),
                    chrono::LocalResult::Ambiguous(dt, _) => dt.offset().local_minus_utc(),
                    chrono::LocalResult::None => {
                        return Err(rusqlite::Error::InvalidParameterName(format!(
                            "Cannot determine timezone for {date_str}"
                        )));
                    }
                };
                naive.and_utc().timestamp_micros() - offset_secs as i64 * 1_000_000
            }
        };

        u64::try_from(ts_micros).map_err(|_| {
            rusqlite::Error::InvalidParameterName(format!(
                "Date {date_str} produces negative timestamp"
            ))
        })
    }

    /// Legacy event-density-based summary. Used as fallback for data recorded
    /// before focus intervals were introduced.
    fn day_summary_event_density(
        &self,
        start: u64,
        end: u64,
    ) -> Result<Vec<ActivityBlock>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT
                (ts / 300000000) * 300000000 as block_start,
                (ts / 300000000) * 300000000 + 300000000 as block_end,
                COALESCE(app_name, 'Unknown') as app,
                COUNT(*) as cnt
             FROM events_index
             WHERE ts >= ?1 AND ts <= ?2 AND app_name IS NOT NULL
             GROUP BY block_start, app
             ORDER BY block_start ASC",
        )?;

        let rows = stmt.query_map(params![start as i64, end as i64], |row| {
            Ok(ActivityBlock {
                start_ts: row.get::<_, i64>(0)? as u64,
                end_ts: row.get::<_, i64>(1)? as u64,
                app_name: row.get(2)?,
                event_count: row.get(3)?,
            })
        })?;

        rows.collect()
    }

    // MARK: - Video Segments

    /// Register a new video recording segment. Called when a new MP4 file is created.
    /// Also mirrors into the unified segments table.
    pub fn insert_video_segment(
        &mut self,
        display_id: u32,
        start_ts: u64,
        file_path: &str,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO video_segments (display_id, start_ts, end_ts, file_path)
             VALUES (?1, ?2, 0, ?3)",
            params![display_id, start_ts as i64, file_path],
        )?;
        // Mirror into unified segments table
        self.register_segment("video", start_ts, file_path)?;
        Ok(())
    }

    /// Update the end timestamp of a video segment. Called when the writer is
    /// finalized (rotation or shutdown). Also updates the unified segments table.
    pub fn finalize_video_segment(
        &mut self,
        file_path: &str,
        end_ts: u64,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE video_segments SET end_ts = ?1 WHERE file_path = ?2",
            params![end_ts as i64, file_path],
        )?;
        // Mirror into unified segments table
        self.conn.execute(
            "UPDATE segments SET end_ts = ?1, status = 'sealed'
             WHERE kind = 'video' AND path = ?2 AND status = 'open'",
            params![end_ts as i64, file_path],
        )?;
        Ok(())
    }

    /// Find the video segment covering a given timestamp for a display.
    /// Enforces strict range membership: start_ts <= target AND (end_ts = 0 OR target <= end_ts).
    /// end_ts = 0 means the segment is still being recorded (open segment).
    pub fn find_video_segment(
        &self,
        display_id: u32,
        timestamp_us: u64,
    ) -> Result<Option<VideoSegment>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT display_id, start_ts, end_ts, file_path
             FROM video_segments
             WHERE display_id = ?1 AND start_ts <= ?2
                   AND (end_ts = 0 OR ?2 <= end_ts)
             ORDER BY start_ts DESC
             LIMIT 1",
        )?;

        let mut rows = stmt.query_map(params![display_id, timestamp_us as i64], |row| {
            Ok(VideoSegment {
                display_id: row.get(0)?,
                start_ts: row.get::<_, i64>(1)? as u64,
                end_ts: row.get::<_, i64>(2)? as u64,
                file_path: row.get(3)?,
            })
        })?;

        match rows.next() {
            Some(Ok(segment)) => Ok(Some(segment)),
            Some(Err(e)) => Err(e),
            None => Ok(None),
        }
    }

    /// List all video segments that overlap with a time range, ordered by start_ts.
    /// Used by the OCR worker to find segments to process.
    pub fn list_video_segments_in_range(
        &self,
        start_us: u64,
        end_us: u64,
    ) -> Result<Vec<VideoSegment>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT display_id, start_ts, end_ts, file_path
             FROM video_segments
             WHERE start_ts < ?2 AND (end_ts = 0 OR end_ts > ?1)
             ORDER BY start_ts ASC",
        )?;

        let rows = stmt.query_map(params![start_us as i64, end_us as i64], |row| {
            Ok(VideoSegment {
                display_id: row.get(0)?,
                start_ts: row.get::<_, i64>(1)? as u64,
                end_ts: row.get::<_, i64>(2)? as u64,
                file_path: row.get(3)?,
            })
        })?;

        rows.collect()
    }

    /// Insert a batch of event headers in a single SQLite transaction.
    /// Each item is (header, segment_file, segment_id) — values may differ per event
    /// if an hourly rotation occurred mid-batch.
    /// Also records app focus intervals for app_switch events.
    pub fn insert_batch(
        &mut self,
        items: &[(&EventHeader, &str, Option<i64>)],
    ) -> Result<(), rusqlite::Error> {
        let tx = self.conn.transaction()?;
        {
            let mut idx_stmt = tx.prepare(
                "INSERT INTO events_index
                    (ts, track, event_type, app_name, window_title, url, segment_file,
                     seq, session_id, display_id, pid, bundle_id, segment_id,
                     ax_role, ax_title, ax_identifier, click_x, click_y)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
            )?;
            let mut close_stmt = tx.prepare(
                "UPDATE app_focus_intervals SET end_ts = ?1 WHERE end_ts = 0",
            )?;
            let mut focus_stmt = tx.prepare(
                "INSERT INTO app_focus_intervals (app_name, bundle_id, start_ts, display_id, session_id)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )?;

            for (header, segment_file, segment_id) in items {
                idx_stmt.execute(params![
                    header.effective_ts() as i64,
                    header.track,
                    header.r#type.as_deref().unwrap_or(""),
                    header.app_name,
                    header.window_title,
                    header.url,
                    segment_file,
                    header.seq.map(|s| s as i64),
                    header.session_id,
                    header.display_id,
                    header.pid,
                    header.bundle_id,
                    segment_id,
                    header.ax_role,
                    header.ax_title,
                    header.ax_identifier,
                    header.click_x,
                    header.click_y,
                ])?;

                // Track app focus intervals for app_switch events
                if header.r#type.as_deref() == Some("app_switch") {
                    if let Some(ref app_name) = header.app_name {
                        close_stmt.execute(params![header.effective_ts() as i64])?;
                        focus_stmt.execute(params![
                            app_name,
                            header.bundle_id,
                            header.effective_ts() as i64,
                            header.display_id,
                            header.session_id,
                        ])?;
                    }
                }
            }
        }
        tx.commit()?;
        Ok(())
    }

    // MARK: - Audio Segments

    /// Register a new audio recording segment. Also mirrors into unified segments table.
    pub fn insert_audio_segment(
        &mut self,
        source: &str,
        start_ts: u64,
        file_path: &str,
        display_id: Option<u32>,
        sample_rate: Option<u32>,
        channels: Option<u32>,
    ) -> Result<i64, rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO audio_segments
                (source, start_ts, file_path, display_id, sample_rate, channels)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![source, start_ts as i64, file_path, display_id, sample_rate, channels],
        )?;
        let segment_id = self.conn.last_insert_rowid();

        // Mirror into unified segments table
        self.register_segment("audio", start_ts, file_path)?;

        Ok(segment_id)
    }

    /// Finalize an audio segment. Also updates the unified segments table.
    pub fn finalize_audio_segment(
        &mut self,
        file_path: &str,
        end_ts: u64,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE audio_segments SET end_ts = ?1 WHERE file_path = ?2",
            params![end_ts as i64, file_path],
        )?;
        // Mirror into unified segments table
        self.conn.execute(
            "UPDATE segments SET end_ts = ?1, status = 'sealed'
             WHERE kind = 'audio' AND path = ?2 AND status = 'open'",
            params![end_ts as i64, file_path],
        )?;
        Ok(())
    }

    /// Find the audio segment covering a given timestamp for a source.
    pub fn find_audio_segment(
        &self,
        source: &str,
        timestamp_us: u64,
    ) -> Result<Option<AudioSegment>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT segment_id, source, start_ts, end_ts, file_path,
                    display_id, sample_rate, channels
             FROM audio_segments
             WHERE source = ?1 AND start_ts <= ?2
                   AND (end_ts = 0 OR ?2 <= end_ts)
             ORDER BY start_ts DESC
             LIMIT 1",
        )?;

        let mut rows = stmt.query_map(params![source, timestamp_us as i64], |row| {
            Ok(AudioSegment {
                segment_id: row.get(0)?,
                source: row.get(1)?,
                start_ts: row.get::<_, i64>(2)? as u64,
                end_ts: row.get::<_, i64>(3)? as u64,
                file_path: row.get(4)?,
                display_id: row.get(5)?,
                sample_rate: row.get(6)?,
                channels: row.get(7)?,
            })
        })?;

        match rows.next() {
            Some(Ok(segment)) => Ok(Some(segment)),
            Some(Err(e)) => Err(e),
            None => Ok(None),
        }
    }

    /// List sealed audio segments overlapping a time range.
    /// Only returns finalized segments (end_ts > 0) — active recordings are excluded.
    /// Used by the transcription worker to discover segments to process.
    pub fn list_audio_segments_in_range(
        &self,
        start_us: u64,
        end_us: u64,
    ) -> Result<Vec<AudioSegment>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT segment_id, source, start_ts, end_ts, file_path,
                    display_id, sample_rate, channels
             FROM audio_segments
             WHERE start_ts < ?2 AND end_ts > ?1 AND end_ts > 0
             ORDER BY start_ts ASC, segment_id ASC",
        )?;

        let rows = stmt.query_map(params![start_us as i64, end_us as i64], |row| {
            Ok(AudioSegment {
                segment_id: row.get(0)?,
                source: row.get(1)?,
                start_ts: row.get::<_, i64>(2)? as u64,
                end_ts: row.get::<_, i64>(3)? as u64,
                file_path: row.get(4)?,
                display_id: row.get::<_, Option<i64>>(5)?.map(|v| v as u32),
                sample_rate: row.get::<_, Option<i64>>(6)?.map(|v| v as u32),
                channels: row.get::<_, Option<i64>>(7)?.map(|v| v as u32),
            })
        })?;

        rows.collect()
    }

    /// List sealed audio segments with segment_id greater than the checkpoint.
    /// Returns segments ordered by segment_id ASC (monotonically increasing, unique).
    /// Used by the transcription worker for skip-safe checkpoint-based pagination.
    ///
    /// This is provably safe:
    /// - segment_id is auto-incrementing INTEGER PRIMARY KEY (unique, monotonic)
    /// - Checkpoint = last processed segment_id
    /// - Next batch: WHERE segment_id > checkpoint → no skips, no duplicates
    /// - Overlapping mic/system segments with identical timestamps are safe
    ///   because they have different segment_ids
    pub fn list_audio_segments_after_checkpoint(
        &self,
        last_segment_id: i64,
        limit: u32,
    ) -> Result<Vec<AudioSegment>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT segment_id, source, start_ts, end_ts, file_path,
                    display_id, sample_rate, channels
             FROM audio_segments
             WHERE segment_id > ?1 AND end_ts > 0
             ORDER BY segment_id ASC
             LIMIT ?2",
        )?;

        let rows = stmt.query_map(params![last_segment_id, limit], |row| {
            Ok(AudioSegment {
                segment_id: row.get(0)?,
                source: row.get(1)?,
                start_ts: row.get::<_, i64>(2)? as u64,
                end_ts: row.get::<_, i64>(3)? as u64,
                file_path: row.get(4)?,
                display_id: row.get::<_, Option<i64>>(5)?.map(|v| v as u32),
                sample_rate: row.get::<_, Option<i64>>(6)?.map(|v| v as u32),
                channels: row.get::<_, Option<i64>>(7)?.map(|v| v as u32),
            })
        })?;

        rows.collect()
    }

    /// Finalize all orphan audio segments (end_ts = 0) from a previous crash.
    /// Sets end_ts to the provided timestamp. Returns the count of orphans finalized.
    pub fn finalize_orphan_audio_segments(&mut self, end_ts: u64) -> Result<u32, rusqlite::Error> {
        let count = self.conn.execute(
            "UPDATE audio_segments SET end_ts = ?1 WHERE end_ts = 0",
            params![end_ts as i64],
        )?;
        // Also seal orphans in unified segments table
        self.conn.execute(
            "UPDATE segments SET end_ts = ?1, status = 'sealed'
             WHERE kind = 'audio' AND status = 'open'",
            params![end_ts as i64],
        )?;
        Ok(count as u32)
    }

    // MARK: - Segments

    /// Register a new segment (events, video, or audio). Returns segment_id.
    pub fn register_segment(
        &mut self,
        kind: &str,
        start_ts: u64,
        path: &str,
    ) -> Result<i64, rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO segments (kind, start_ts, path, status)
             VALUES (?1, ?2, ?3, 'open')",
            params![kind, start_ts as i64, path],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Update a segment's status and optionally end_ts, path, and compression.
    /// NULL parameters preserve existing values via COALESCE.
    pub fn update_segment(
        &mut self,
        segment_id: i64,
        status: &str,
        end_ts: Option<u64>,
        path: Option<&str>,
        compression: Option<&str>,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE segments SET
                status = ?1,
                end_ts = COALESCE(?2, end_ts),
                path = COALESCE(?3, path),
                compression = COALESCE(?4, compression)
             WHERE segment_id = ?5",
            params![
                status,
                end_ts.map(|t| t as i64),
                path,
                compression,
                segment_id,
            ],
        )?;
        Ok(())
    }

    /// Resolve the current event segment_id for a given path.
    /// Cache-first: returns immediately if the path matches the cached segment.
    /// On path change (rotation), seals the previous segment and registers a new one.
    pub fn resolve_event_segment(
        &mut self,
        path: &str,
        ts: u64,
    ) -> Result<i64, rusqlite::Error> {
        // Fast path: cached segment matches
        if let Some((id, ref cached_path)) = self.event_segment_cache {
            if cached_path == path {
                return Ok(id);
            }
            // Path changed — rotation happened. Close old segment.
            self.update_segment(id, "sealed", Some(ts), None, None)?;
        }

        // Register new segment
        let new_id = self.register_segment("events", ts, path)?;
        self.event_segment_cache = Some((new_id, path.to_string()));
        Ok(new_id)
    }

    /// Seal the current event segment with optional compressed path info.
    /// Called after rotation when the compressed path is known.
    pub fn seal_current_event_segment(
        &mut self,
        end_ts: u64,
        compressed_path: Option<&str>,
        compression: Option<&str>,
    ) -> Result<(), rusqlite::Error> {
        if let Some((id, _)) = self.event_segment_cache.take() {
            self.update_segment(id, "sealed", Some(end_ts), compressed_path, compression)?;
        }
        Ok(())
    }

    // MARK: - App Focus Intervals

    /// Record an app gaining focus. Call on every app_switch event.
    /// Closes the previous open interval (if any) and opens a new one.
    pub fn record_app_focus(
        &mut self,
        app_name: &str,
        bundle_id: Option<&str>,
        ts: u64,
        display_id: Option<u32>,
        session_id: Option<&str>,
    ) -> Result<(), rusqlite::Error> {
        // Close the previous open interval
        self.conn.execute(
            "UPDATE app_focus_intervals SET end_ts = ?1 WHERE end_ts = 0",
            params![ts as i64],
        )?;

        // Open a new interval
        self.conn.execute(
            "INSERT INTO app_focus_intervals (app_name, bundle_id, start_ts, display_id, session_id)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![app_name, bundle_id, ts as i64, display_id, session_id],
        )?;

        Ok(())
    }

    /// Close any open focus interval (e.g., on session end / sleep).
    pub fn close_open_focus_interval(&mut self, ts: u64) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE app_focus_intervals SET end_ts = ?1 WHERE end_ts = 0",
            params![ts as i64],
        )?;
        Ok(())
    }

    /// Query app focus intervals in a time range. Returns occupancy-based blocks.
    pub fn query_focus_intervals(
        &self,
        start_us: u64,
        end_us: u64,
    ) -> Result<Vec<ActivityBlock>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT app_name,
                    MAX(start_ts, ?1) as effective_start,
                    CASE WHEN end_ts = 0 THEN ?2 ELSE MIN(end_ts, ?2) END as effective_end
             FROM app_focus_intervals
             WHERE start_ts < ?2 AND (end_ts = 0 OR end_ts > ?1)
             ORDER BY start_ts ASC",
        )?;

        let rows = stmt.query_map(params![start_us as i64, end_us as i64], |row| {
            let start: i64 = row.get(1)?;
            let end: i64 = row.get(2)?;
            Ok(ActivityBlock {
                start_ts: start as u64,
                end_ts: end as u64,
                app_name: row.get(0)?,
                event_count: 1, // each interval is one focus period
            })
        })?;

        rows.collect()
    }

    /// Find which app was focused at a specific timestamp.
    /// Queries the app_focus_intervals table for the interval containing the given timestamp.
    /// Returns None if no interval covers that timestamp (e.g., during gaps, sleep, or before recording started).
    pub fn find_app_at_timestamp(&self, ts_us: u64) -> Result<Option<AppContext>, rusqlite::Error> {
        let result: Result<(String, Option<String>), _> = self.conn.query_row(
            "SELECT app_name, bundle_id FROM app_focus_intervals
             WHERE start_ts <= ?1 AND (end_ts = 0 OR end_ts > ?1)
             ORDER BY start_ts DESC LIMIT 1",
            params![ts_us as i64],
            |row| Ok((row.get(0)?, row.get(1)?)),
        );

        match result {
            Ok((app_name, bundle_id)) => Ok(Some(AppContext { app_name, bundle_id })),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e),
        }
    }

    // MARK: - Integrity Checks

    /// Check segment reference integrity. Returns counts of:
    /// - stale_segment_refs: events_index rows with segment_id pointing to non-existent segments
    /// - total_events: total rows in events_index
    /// - events_with_segment_id: rows that have a non-null segment_id
    /// - segments_count: total rows in segments table
    pub fn check_segment_integrity(
        &self,
    ) -> Result<IntegrityReport, rusqlite::Error> {
        let stale_refs: i64 = self.conn.query_row(
            "SELECT COUNT(*)
             FROM events_index e
             LEFT JOIN segments s ON e.segment_id = s.segment_id
             WHERE e.segment_id IS NOT NULL AND s.segment_id IS NULL",
            [],
            |row| row.get(0),
        )?;

        let total_events: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM events_index",
            [],
            |row| row.get(0),
        )?;

        let events_with_segment_id: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM events_index WHERE segment_id IS NOT NULL",
            [],
            |row| row.get(0),
        )?;

        let segments_count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM segments",
            [],
            |row| row.get(0),
        )?;

        let video_segments_count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM video_segments",
            [],
            |row| row.get(0),
        )?;

        let audio_segments_count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM audio_segments",
            [],
            |row| row.get(0),
        )?;

        // Check ordering sanity: any events with seq out of order within session
        let ordering_violations: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM (
                SELECT session_id, seq, LAG(seq) OVER (PARTITION BY session_id ORDER BY ts) as prev_seq
                FROM events_index
                WHERE session_id IS NOT NULL AND seq IS NOT NULL
             ) WHERE prev_seq IS NOT NULL AND seq <= prev_seq",
            [],
            |row| row.get(0),
        )?;

        // Get all segment paths for file existence check
        let mut path_stmt = self.conn.prepare(
            "SELECT path, status FROM segments WHERE status != 'open'"
        )?;
        let segment_paths: Vec<SegmentPathEntry> = path_stmt
            .query_map([], |row| Ok(SegmentPathEntry {
                path: row.get(0)?,
                status: row.get(1)?,
            }))?
            .filter_map(|r| r.ok())
            .collect();

        Ok(IntegrityReport {
            stale_segment_refs: stale_refs as u64,
            total_events: total_events as u64,
            events_with_segment_id: events_with_segment_id as u64,
            segments_count: segments_count as u64,
            video_segments_count: video_segments_count as u64,
            audio_segments_count: audio_segments_count as u64,
            ordering_violations: ordering_violations as u64,
            sealed_segment_paths: segment_paths,
        })
    }

    // MARK: - Capture Sessions

    /// Register a new capture session.
    pub fn register_session(
        &mut self,
        session_id: &str,
        start_ts: u64,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT OR IGNORE INTO capture_sessions (session_id, start_ts, status)
             VALUES (?1, ?2, 'active')",
            params![session_id, start_ts as i64],
        )?;
        Ok(())
    }

    // MARK: - Index Checkpoints

    /// Get the last indexed timestamp for a named index.
    /// Returns 0 if no checkpoint exists (index has never run).
    pub fn get_checkpoint(&self, index_name: &str) -> Result<u64, rusqlite::Error> {
        let ts: i64 = self
            .conn
            .query_row(
                "SELECT last_ts FROM index_checkpoints WHERE index_name = ?1",
                params![index_name],
                |row| row.get(0),
            )
            .unwrap_or(0);

        Ok(ts as u64)
    }

    /// Update the checkpoint for a named index. Upserts (insert or replace).
    pub fn set_checkpoint(&mut self, index_name: &str, last_ts: u64) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO index_checkpoints (index_name, last_ts)
             VALUES (?1, ?2)
             ON CONFLICT(index_name) DO UPDATE SET last_ts = ?2",
            params![index_name, last_ts as i64],
        )?;
        Ok(())
    }

    /// Finalize a capture session.
    pub fn finalize_session(
        &mut self,
        session_id: &str,
        end_ts: u64,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE capture_sessions SET end_ts = ?1, status = 'ended'
             WHERE session_id = ?2",
            params![end_ts as i64, session_id],
        )?;
        Ok(())
    }

    // MARK: - Visual Change Log

    /// Record a visual change distance measurement from OCRWorker.
    /// Called for every 10-second sample regardless of whether OCR runs.
    /// Uses INSERT OR REPLACE so re-processing the same timestamp is idempotent.
    pub fn record_visual_change(
        &self,
        display_id: u32,
        timestamp_us: u64,
        distance: f32,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT OR REPLACE INTO visual_change_log (display_id, timestamp_us, distance)
             VALUES (?1, ?2, ?3)",
            params![display_id, timestamp_us as i64, distance as f64],
        )?;
        Ok(())
    }

    /// Query timestamps where visual change exceeds a threshold within a time range.
    /// Returns timestamps in ascending order. Used by keyframe extraction.
    pub fn query_visual_changes(
        &self,
        display_id: u32,
        start_ts: u64,
        end_ts: u64,
        min_distance: f32,
    ) -> Result<Vec<u64>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT timestamp_us FROM visual_change_log
             WHERE display_id = ?1
               AND timestamp_us BETWEEN ?2 AND ?3
               AND distance > ?4
             ORDER BY timestamp_us",
        )?;
        let timestamps = stmt
            .query_map(
                params![
                    display_id,
                    start_ts as i64,
                    end_ts as i64,
                    min_distance as f64
                ],
                |row| row.get::<_, i64>(0).map(|v| v as u64),
            )?
            .filter_map(|r| r.ok())
            .collect();
        Ok(timestamps)
    }

    // MARK: - Retention Tier Management

    /// List sealed video segments in a given retention tier older than cutoff.
    /// Skips segments with end_ts = 0 (currently recording) and deleted segments.
    pub fn list_video_segments_for_retention(
        &self,
        current_tier: &str,
        cutoff_ts: u64,
    ) -> Result<Vec<VideoSegment>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT display_id, start_ts, end_ts, file_path
             FROM video_segments
             WHERE retention_tier = ?1
               AND end_ts > 0
               AND end_ts < ?2
               AND deleted_at IS NULL
             ORDER BY end_ts ASC",
        )?;
        let segments = stmt
            .query_map(params![current_tier, cutoff_ts as i64], |row| {
                Ok(VideoSegment {
                    display_id: row.get(0)?,
                    start_ts: row.get::<_, i64>(1)? as u64,
                    end_ts: row.get::<_, i64>(2)? as u64,
                    file_path: row.get(3)?,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();
        Ok(segments)
    }

    /// Update the retention tier of a video segment.
    pub fn update_video_segment_tier(
        &self,
        file_path: &str,
        new_tier: &str,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE video_segments SET retention_tier = ?1 WHERE file_path = ?2",
            params![new_tier, file_path],
        )?;
        Ok(())
    }

    /// Find a video segment by its file path.
    pub fn find_video_segment_by_path(
        &self,
        file_path: &str,
    ) -> Result<Option<VideoSegment>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT display_id, start_ts, end_ts, file_path
             FROM video_segments
             WHERE file_path = ?1
             LIMIT 1",
        )?;
        let mut rows = stmt.query_map(params![file_path], |row| {
            Ok(VideoSegment {
                display_id: row.get(0)?,
                start_ts: row.get::<_, i64>(1)? as u64,
                end_ts: row.get::<_, i64>(2)? as u64,
                file_path: row.get(3)?,
            })
        })?;
        match rows.next() {
            Some(Ok(segment)) => Ok(Some(segment)),
            Some(Err(e)) => Err(e),
            None => Ok(None),
        }
    }

    /// Insert a keyframe record. Uses INSERT OR IGNORE for idempotency --
    /// if a keyframe with the same file_path already exists, skip silently.
    pub fn insert_keyframe(
        &self,
        display_id: u32,
        ts: u64,
        file_path: &str,
        source_segment: &str,
        size_bytes: Option<u64>,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT OR IGNORE INTO keyframes (display_id, ts, file_path, source_segment, size_bytes)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                display_id,
                ts as i64,
                file_path,
                source_segment,
                size_bytes.map(|s| s as i64)
            ],
        )?;
        Ok(())
    }

    /// Find keyframe nearest to a timestamp for a display.
    /// Uses two bounded queries (closest-before + closest-after) instead of
    /// ORDER BY ABS() which cannot use the (display_id, ts) index.
    ///
    /// A max-distance bound of 1 hour (3_600_000_000 microseconds) prevents
    /// returning an unrelated keyframe from a completely different time period.
    pub fn find_nearest_keyframe(
        &self,
        display_id: u32,
        timestamp_us: u64,
    ) -> Result<Option<String>, rusqlite::Error> {
        let ts = timestamp_us as i64;
        let max_distance_us: i64 = 3_600_000_000;

        // Closest keyframe at or before the target (within max distance)
        let before: Option<(i64, String)> = match self.conn.query_row(
            "SELECT ts, file_path FROM keyframes
             WHERE display_id = ?1 AND ts <= ?2 AND ts >= ?3
             ORDER BY ts DESC
             LIMIT 1",
            params![display_id, ts, ts - max_distance_us],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ) {
            Ok(v) => Some(v),
            Err(rusqlite::Error::QueryReturnedNoRows) => None,
            Err(e) => return Err(e),
        };

        // Closest keyframe after the target (within max distance)
        let after: Option<(i64, String)> = match self.conn.query_row(
            "SELECT ts, file_path FROM keyframes
             WHERE display_id = ?1 AND ts > ?2 AND ts <= ?3
             ORDER BY ts ASC
             LIMIT 1",
            params![display_id, ts, ts + max_distance_us],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ) {
            Ok(v) => Some(v),
            Err(rusqlite::Error::QueryReturnedNoRows) => None,
            Err(e) => return Err(e),
        };

        // Pick whichever is closer
        match (before, after) {
            (Some((bt, bp)), Some((at, ap))) => {
                if (ts - bt) <= (at - ts) {
                    Ok(Some(bp))
                } else {
                    Ok(Some(ap))
                }
            }
            (Some((_, bp)), None) => Ok(Some(bp)),
            (None, Some((_, ap))) => Ok(Some(ap)),
            (None, None) => Ok(None),
        }
    }

    /// List keyframe file paths for a given source segment.
    pub fn list_keyframe_paths_for_segment(
        &self,
        source_segment: &str,
    ) -> Result<Vec<String>, rusqlite::Error> {
        let mut stmt = self
            .conn
            .prepare("SELECT file_path FROM keyframes WHERE source_segment = ?1")?;
        let paths: Vec<String> = stmt
            .query_map(params![source_segment], |row| row.get(0))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(paths)
    }

    /// Delete keyframe DB rows for a given source segment.
    /// Returns the number of rows deleted.
    pub fn delete_keyframe_rows_for_segment(
        &self,
        source_segment: &str,
    ) -> Result<usize, rusqlite::Error> {
        self.conn.execute(
            "DELETE FROM keyframes WHERE source_segment = ?1",
            params![source_segment],
        )
    }

    // MARK: - AX Snapshots (Agent System Phase 1)

    /// Insert an AX tree snapshot record.
    pub fn insert_ax_snapshot(
        &self,
        timestamp_us: u64,
        app_bundle_id: &str,
        app_name: &str,
        window_title: Option<&str>,
        display_id: Option<u32>,
        tree_hash: u64,
        node_count: u32,
        trigger: Option<&str>,
    ) -> Result<i64, rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO ax_snapshots
                (timestamp_us, app_bundle_id, app_name, window_title,
                 display_id, tree_hash, node_count, trigger)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                timestamp_us as i64,
                app_bundle_id,
                app_name,
                window_title,
                display_id,
                tree_hash as i64,
                node_count,
                trigger,
            ],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Find an AX snapshot by approximate timestamp (nearest within 5 seconds).
    pub fn find_ax_snapshot(
        &self,
        timestamp_us: u64,
    ) -> Result<Option<AxSnapshotRecord>, rusqlite::Error> {
        let ts = timestamp_us as i64;
        let window = 5_000_000i64; // 5 seconds
        let mut stmt = self.conn.prepare(
            "SELECT id, timestamp_us, app_bundle_id, app_name, window_title,
                    display_id, tree_hash, node_count, trigger
             FROM ax_snapshots
             WHERE timestamp_us BETWEEN ?1 AND ?2
             ORDER BY ABS(timestamp_us - ?3) ASC
             LIMIT 1",
        )?;
        let result = stmt
            .query_row(params![ts - window, ts + window, ts], |row| {
                Ok(AxSnapshotRecord {
                    id: row.get(0)?,
                    timestamp_us: row.get::<_, i64>(1)? as u64,
                    app_bundle_id: row.get(2)?,
                    app_name: row.get(3)?,
                    window_title: row.get(4)?,
                    display_id: row.get(5)?,
                    tree_hash: row.get::<_, i64>(6)? as u64,
                    node_count: row.get(7)?,
                    trigger: row.get(8)?,
                })
            })
            .optional();
        result
    }

    /// Query AX snapshots for an app within a time range.
    pub fn query_ax_snapshots(
        &self,
        app_bundle_id: Option<&str>,
        start_ts: u64,
        end_ts: u64,
        limit: u32,
    ) -> Result<Vec<AxSnapshotRecord>, rusqlite::Error> {
        if let bundle_id = app_bundle_id {
            let mut stmt = self.conn.prepare(
                "SELECT id, timestamp_us, app_bundle_id, app_name, window_title,
                        display_id, tree_hash, node_count, trigger
                 FROM ax_snapshots
                 WHERE app_bundle_id = ?1 AND timestamp_us BETWEEN ?2 AND ?3
                 ORDER BY timestamp_us DESC
                 LIMIT ?4",
            )?;
            let rows = stmt.query_map(
                params![bundle_id, start_ts as i64, end_ts as i64, limit],
                |row| {
                    Ok(AxSnapshotRecord {
                        id: row.get(0)?,
                        timestamp_us: row.get::<_, i64>(1)? as u64,
                        app_bundle_id: row.get(2)?,
                        app_name: row.get(3)?,
                        window_title: row.get(4)?,
                        display_id: row.get(5)?,
                        tree_hash: row.get::<_, i64>(6)? as u64,
                        node_count: row.get(7)?,
                        trigger: row.get(8)?,
                    })
                },
            )?;
            rows.collect()
        } else {
            let mut stmt = self.conn.prepare(
                "SELECT id, timestamp_us, app_bundle_id, app_name, window_title,
                        display_id, tree_hash, node_count, trigger
                 FROM ax_snapshots
                 WHERE timestamp_us BETWEEN ?1 AND ?2
                 ORDER BY timestamp_us DESC
                 LIMIT ?3",
            )?;
            let rows = stmt.query_map(
                params![start_ts as i64, end_ts as i64, limit],
                |row| {
                    Ok(AxSnapshotRecord {
                        id: row.get(0)?,
                        timestamp_us: row.get::<_, i64>(1)? as u64,
                        app_bundle_id: row.get(2)?,
                        app_name: row.get(3)?,
                        window_title: row.get(4)?,
                        display_id: row.get(5)?,
                        tree_hash: row.get::<_, i64>(6)? as u64,
                        node_count: row.get(7)?,
                        trigger: row.get(8)?,
                    })
                },
            )?;
            rows.collect()
        }
    }

    // MARK: - Procedure CRUD

    /// Insert or replace a procedure record.
    pub fn insert_procedure(
        &self,
        id: &str,
        name: &str,
        description: &str,
        source_app: &str,
        source_bundle_id: &str,
        step_count: u32,
        parameter_count: u32,
        tags: &str,
        created_at: u64,
        updated_at: u64,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT OR REPLACE INTO procedures
             (id, name, description, source_app, source_bundle_id,
              step_count, parameter_count, tags, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                id,
                name,
                description,
                source_app,
                source_bundle_id,
                step_count,
                parameter_count,
                tags,
                created_at as i64,
                updated_at as i64
            ],
        )?;
        Ok(())
    }

    /// Query procedures, optionally filtering by source app.
    pub fn query_procedures(
        &self,
        source_app: Option<&str>,
        limit: u32,
    ) -> Result<Vec<ProcedureRecord>, rusqlite::Error> {
        if let app = source_app {
            let mut stmt = self.conn.prepare(
                "SELECT id, name, description, source_app, source_bundle_id,
                        step_count, parameter_count, tags, created_at, updated_at
                 FROM procedures
                 WHERE source_app = ?1
                 ORDER BY updated_at DESC
                 LIMIT ?2",
            )?;
            let rows = stmt.query_map(params![app, limit], |row| {
                Ok(ProcedureRecord {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    source_app: row.get(3)?,
                    source_bundle_id: row.get(4)?,
                    step_count: row.get(5)?,
                    parameter_count: row.get(6)?,
                    tags: row.get(7)?,
                    created_at: row.get::<_, i64>(8)? as u64,
                    updated_at: row.get::<_, i64>(9)? as u64,
                })
            })?;
            rows.collect()
        } else {
            let mut stmt = self.conn.prepare(
                "SELECT id, name, description, source_app, source_bundle_id,
                        step_count, parameter_count, tags, created_at, updated_at
                 FROM procedures
                 ORDER BY updated_at DESC
                 LIMIT ?1",
            )?;
            let rows = stmt.query_map(params![limit], |row| {
                Ok(ProcedureRecord {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    source_app: row.get(3)?,
                    source_bundle_id: row.get(4)?,
                    step_count: row.get(5)?,
                    parameter_count: row.get(6)?,
                    tags: row.get(7)?,
                    created_at: row.get::<_, i64>(8)? as u64,
                    updated_at: row.get::<_, i64>(9)? as u64,
                })
            })?;
            rows.collect()
        }
    }

    /// Delete a procedure by ID.
    pub fn delete_procedure(&self, id: &str) -> Result<(), rusqlite::Error> {
        self.conn
            .execute("DELETE FROM procedures WHERE id = ?1", params![id])?;
        Ok(())
    }

    // --- Semantic Knowledge CRUD (Phase 5) ---

    /// Insert or replace a semantic knowledge record.
    pub fn upsert_semantic_knowledge(
        &self,
        id: &str,
        category: &str,
        key: &str,
        value: &str,
        confidence: f64,
        source_episode_ids: &str,
        created_at: u64,
        updated_at: u64,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT OR REPLACE INTO semantic_knowledge
             (id, category, key, value, confidence, source_episode_ids, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                id,
                category,
                key,
                value,
                confidence,
                source_episode_ids,
                created_at as i64,
                updated_at as i64
            ],
        )?;
        Ok(())
    }

    /// Query semantic knowledge by category.
    pub fn query_semantic_knowledge(
        &self,
        category: Option<&str>,
        limit: u32,
    ) -> Result<Vec<SemanticKnowledgeRecord>, rusqlite::Error> {
        if let Some(cat) = category {
            let mut stmt = self.conn.prepare(
                "SELECT id, category, key, value, confidence, source_episode_ids,
                        created_at, updated_at, access_count, last_accessed_at
                 FROM semantic_knowledge
                 WHERE category = ?1
                 ORDER BY updated_at DESC
                 LIMIT ?2",
            )?;
            let rows = stmt.query_map(params![cat, limit], |row| {
                Ok(SemanticKnowledgeRecord {
                    id: row.get(0)?,
                    category: row.get(1)?,
                    key: row.get(2)?,
                    value: row.get(3)?,
                    confidence: row.get(4)?,
                    source_episode_ids: row.get(5)?,
                    created_at: row.get::<_, i64>(6)? as u64,
                    updated_at: row.get::<_, i64>(7)? as u64,
                    access_count: row.get(8)?,
                    last_accessed_at: row.get::<_, Option<i64>>(9)?.map(|v| v as u64),
                })
            })?;
            rows.collect()
        } else {
            let mut stmt = self.conn.prepare(
                "SELECT id, category, key, value, confidence, source_episode_ids,
                        created_at, updated_at, access_count, last_accessed_at
                 FROM semantic_knowledge
                 ORDER BY updated_at DESC
                 LIMIT ?1",
            )?;
            let rows = stmt.query_map(params![limit], |row| {
                Ok(SemanticKnowledgeRecord {
                    id: row.get(0)?,
                    category: row.get(1)?,
                    key: row.get(2)?,
                    value: row.get(3)?,
                    confidence: row.get(4)?,
                    source_episode_ids: row.get(5)?,
                    created_at: row.get::<_, i64>(6)? as u64,
                    updated_at: row.get::<_, i64>(7)? as u64,
                    access_count: row.get(8)?,
                    last_accessed_at: row.get::<_, Option<i64>>(9)?.map(|v| v as u64),
                })
            })?;
            rows.collect()
        }
    }

    /// Record an access to a semantic knowledge record.
    pub fn touch_semantic_knowledge(&self, id: &str, now_us: u64) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE semantic_knowledge
             SET access_count = access_count + 1, last_accessed_at = ?1
             WHERE id = ?2",
            params![now_us as i64, id],
        )?;
        Ok(())
    }

    /// Delete a semantic knowledge record by ID.
    pub fn delete_semantic_knowledge(&self, id: &str) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "DELETE FROM semantic_knowledge WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }

    // --- Directives CRUD (Phase 5) ---

    /// Insert or replace a directive record.
    pub fn upsert_directive(
        &self,
        id: &str,
        directive_type: &str,
        trigger_pattern: &str,
        action_description: &str,
        priority: i32,
        created_at: u64,
        expires_at: Option<u64>,
        source_context: &str,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT OR REPLACE INTO directives
             (id, directive_type, trigger_pattern, action_description,
              priority, created_at, expires_at, is_active, source_context)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, ?8)",
            params![
                id,
                directive_type,
                trigger_pattern,
                action_description,
                priority,
                created_at as i64,
                expires_at.map(|v| v as i64),
                source_context
            ],
        )?;
        Ok(())
    }

    /// Query active directives, excluding expired ones.
    pub fn query_active_directives(
        &self,
        now_us: u64,
        limit: u32,
    ) -> Result<Vec<DirectiveRecord>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT id, directive_type, trigger_pattern, action_description,
                    priority, created_at, expires_at, is_active,
                    execution_count, last_triggered_at, source_context
             FROM directives
             WHERE is_active = 1
               AND (expires_at IS NULL OR expires_at > ?1)
             ORDER BY priority DESC, created_at DESC
             LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![now_us as i64, limit], |row| {
            Ok(DirectiveRecord {
                id: row.get(0)?,
                directive_type: row.get(1)?,
                trigger_pattern: row.get(2)?,
                action_description: row.get(3)?,
                priority: row.get(4)?,
                created_at: row.get::<_, i64>(5)? as u64,
                expires_at: row.get::<_, Option<i64>>(6)?.map(|v| v as u64),
                is_active: row.get::<_, i32>(7)? != 0,
                execution_count: row.get(8)?,
                last_triggered_at: row.get::<_, Option<i64>>(9)?.map(|v| v as u64),
                source_context: row.get(10)?,
            })
        })?;
        rows.collect()
    }

    /// Record a directive trigger execution.
    pub fn record_directive_trigger(
        &self,
        id: &str,
        now_us: u64,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE directives
             SET execution_count = execution_count + 1, last_triggered_at = ?1
             WHERE id = ?2",
            params![now_us as i64, id],
        )?;
        Ok(())
    }

    /// Deactivate a directive.
    pub fn deactivate_directive(&self, id: &str) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE directives SET is_active = 0 WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }

    /// Delete a directive by ID.
    pub fn delete_directive(&self, id: &str) -> Result<(), rusqlite::Error> {
        self.conn
            .execute("DELETE FROM directives WHERE id = ?1", params![id])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_insert_and_query_v1() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        let header = EventHeader {
            ts: 1708300800000000,
            track: 3,
            r#type: Some("app_switch".into()),
            app_name: Some("VS Code".into()),
            window_title: Some("main.rs".into()),
            url: None,
            v: None,
            ts_wall_us: None,
            ts_mono_ns: None,
            seq: None,
            session_id: None,
            source: None,
            display_id: None,
            pid: None,
            bundle_id: None,
            ax_role: None,
            ax_title: None,
            ax_identifier: None,
            click_x: None,
            click_y: None,
        };

        index
            .insert(&header, "events/2024-02-19/14.msgpack", None)
            .unwrap();

        let results = index
            .query_range(1708300000000000, 1708301000000000)
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].app_name.as_deref(), Some("VS Code"));
    }

    #[test]
    fn test_insert_v2_event() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        let header = EventHeader {
            ts: 1771645325123456,
            track: 2,
            r#type: Some("key_down".into()),
            app_name: Some("Chrome".into()),
            window_title: Some("Gmail".into()),
            url: Some("https://mail.google.com".into()),
            v: Some(2),
            ts_wall_us: Some(1771645325123456),
            ts_mono_ns: Some(88231511223344),
            seq: Some(42),
            session_id: Some("test-session-1".into()),
            source: Some("input_monitor".into()),
            display_id: Some(69734112),
            pid: Some(1234),
            bundle_id: Some("com.google.Chrome".into()),
            ax_role: None,
            ax_title: None,
            ax_identifier: None,
            click_x: None,
            click_y: None,
        };

        index
            .insert(&header, "events/2026-02-21/14.msgpack", Some(1))
            .unwrap();

        let results = index
            .query_range(1771645325000000, 1771645326000000)
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].app_name.as_deref(), Some("Chrome"));
    }

    #[test]
    fn test_segments_lifecycle() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        let seg_id = index
            .register_segment("events", 1000000, "/path/to/segment.msgpack")
            .unwrap();
        assert!(seg_id > 0);

        // Simulate rotation: close and update path/compression
        index
            .update_segment(
                seg_id,
                "sealed",
                Some(2000000),
                Some("/path/to/segment.msgpack.zst"),
                Some("zstd"),
            )
            .unwrap();
    }

    #[test]
    fn test_session_lifecycle() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        index.register_session("test-session-1", 1000000).unwrap();
        index
            .finalize_session("test-session-1", 2000000)
            .unwrap();
    }

    #[test]
    fn test_video_segment_lookup_range() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Segment 1: 1000-2000 (closed)
        index.insert_video_segment(1, 1000, "/seg1.mp4").unwrap();
        index.finalize_video_segment("/seg1.mp4", 2000).unwrap();

        // Gap: 2001-2999

        // Segment 2: 3000-still open
        index.insert_video_segment(1, 3000, "/seg2.mp4").unwrap();

        // Query within segment 1
        let seg = index.find_video_segment(1, 1500).unwrap();
        assert!(seg.is_some());
        assert_eq!(seg.unwrap().file_path, "/seg1.mp4");

        // Query in the gap — should return None (not seg1!)
        let seg = index.find_video_segment(1, 2500).unwrap();
        assert!(seg.is_none(), "Gap query should return None, not stale segment");

        // Query within open segment 2
        let seg = index.find_video_segment(1, 3500).unwrap();
        assert!(seg.is_some());
        assert_eq!(seg.unwrap().file_path, "/seg2.mp4");

        // Query at exact boundary: start of segment 1
        let seg = index.find_video_segment(1, 1000).unwrap();
        assert!(seg.is_some());
        assert_eq!(seg.unwrap().file_path, "/seg1.mp4");

        // Query at exact boundary: end of segment 1
        let seg = index.find_video_segment(1, 2000).unwrap();
        assert!(seg.is_some());
        assert_eq!(seg.unwrap().file_path, "/seg1.mp4");

        // Query before any segments
        let seg = index.find_video_segment(1, 500).unwrap();
        assert!(seg.is_none());
    }

    #[test]
    fn test_batch_insert() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        let h1 = EventHeader {
            ts: 1000000, track: 2, r#type: Some("key_down".into()),
            app_name: Some("Chrome".into()), window_title: None, url: None,
            v: Some(2), ts_wall_us: Some(1000000), ts_mono_ns: Some(100),
            seq: Some(1), session_id: Some("s1".into()), source: Some("input_monitor".into()),
            display_id: None, pid: None, bundle_id: None,
            ax_role: None, ax_title: None, ax_identifier: None, click_x: None, click_y: None,
        };
        let h2 = EventHeader {
            ts: 2000000, track: 3, r#type: Some("app_switch".into()),
            app_name: Some("VS Code".into()), window_title: Some("main.rs".into()), url: None,
            v: Some(2), ts_wall_us: Some(2000000), ts_mono_ns: Some(200),
            seq: Some(2), session_id: Some("s1".into()), source: Some("window_tracker".into()),
            display_id: None, pid: None, bundle_id: None,
            ax_role: None, ax_title: None, ax_identifier: None, click_x: None, click_y: None,
        };

        let items: Vec<(&EventHeader, &str, Option<i64>)> = vec![
            (&h1, "events/2026-02-21/14.msgpack", Some(1)),
            (&h2, "events/2026-02-21/14.msgpack", Some(1)),
        ];

        index.insert_batch(&items).unwrap();

        let results = index.query_range(0, 3000000).unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].app_name.as_deref(), Some("Chrome"));
        assert_eq!(results[1].app_name.as_deref(), Some("VS Code"));
    }

    #[test]
    fn test_resolve_event_segment() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // First resolve: creates a new segment
        let id1 = index
            .resolve_event_segment("/path/to/hour14.msgpack", 1000000)
            .unwrap();
        assert!(id1 > 0);

        // Same path: returns cached id
        let id2 = index
            .resolve_event_segment("/path/to/hour14.msgpack", 1500000)
            .unwrap();
        assert_eq!(id1, id2);

        // Different path (rotation): seals old, creates new
        let id3 = index
            .resolve_event_segment("/path/to/hour15.msgpack", 2000000)
            .unwrap();
        assert_ne!(id1, id3);

        // Verify old segment was sealed
        let status: String = index
            .conn
            .query_row(
                "SELECT status FROM segments WHERE segment_id = ?1",
                params![id1],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "sealed");

        // Verify new segment is open
        let status: String = index
            .conn
            .query_row(
                "SELECT status FROM segments WHERE segment_id = ?1",
                params![id3],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "open");
    }

    #[test]
    fn test_seal_event_segment_with_compression() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        let id = index
            .resolve_event_segment("/path/to/hour14.msgpack", 1000000)
            .unwrap();

        // Seal with compression info
        index
            .seal_current_event_segment(
                2000000,
                Some("/path/to/hour14.msgpack.zst"),
                Some("zstd"),
            )
            .unwrap();

        // Verify segment was updated
        let (status, path, compression): (String, String, Option<String>) = index
            .conn
            .query_row(
                "SELECT status, path, compression FROM segments WHERE segment_id = ?1",
                params![id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(status, "sealed");
        assert_eq!(path, "/path/to/hour14.msgpack.zst");
        assert_eq!(compression.as_deref(), Some("zstd"));

        // Cache should be cleared — next resolve creates new
        let id2 = index
            .resolve_event_segment("/path/to/hour15.msgpack", 3000000)
            .unwrap();
        assert_ne!(id, id2);
    }

    #[test]
    fn test_video_segment_mirrors_to_segments() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Insert video segment — should also appear in segments table
        index.insert_video_segment(1, 1000, "/video/seg1.mp4").unwrap();

        let (kind, status): (String, String) = index
            .conn
            .query_row(
                "SELECT kind, status FROM segments WHERE path = ?1",
                params!["/video/seg1.mp4"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(kind, "video");
        assert_eq!(status, "open");

        // Finalize — should update both tables
        index.finalize_video_segment("/video/seg1.mp4", 2000).unwrap();

        let status: String = index
            .conn
            .query_row(
                "SELECT status FROM segments WHERE path = ?1",
                params!["/video/seg1.mp4"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "sealed");
    }

    #[test]
    fn test_focus_intervals() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Simulate app switches: Chrome 1000-2000, VS Code 2000-3000
        index
            .record_app_focus("Chrome", Some("com.google.Chrome"), 1000, None, None)
            .unwrap();
        index
            .record_app_focus("VS Code", Some("com.microsoft.VSCode"), 2000, None, None)
            .unwrap();
        // Close the last interval
        index.close_open_focus_interval(3000).unwrap();

        // Query full range
        let blocks = index.query_focus_intervals(0, 4000).unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].app_name, "Chrome");
        assert_eq!(blocks[0].start_ts, 1000);
        assert_eq!(blocks[0].end_ts, 2000);
        assert_eq!(blocks[1].app_name, "VS Code");
        assert_eq!(blocks[1].start_ts, 2000);
        assert_eq!(blocks[1].end_ts, 3000);

        // Query partial range: only VS Code visible
        let blocks = index.query_focus_intervals(2500, 4000).unwrap();
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].app_name, "VS Code");
        // Effective start should be clamped to query start
        assert_eq!(blocks[0].start_ts, 2500);
    }

    #[test]
    fn test_find_app_at_timestamp() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Create intervals: Chrome 1000-2000, VS Code 2000-3000
        index
            .record_app_focus("Chrome", Some("com.google.Chrome"), 1000, None, None)
            .unwrap();
        index
            .record_app_focus("VS Code", Some("com.microsoft.VSCode"), 2000, None, None)
            .unwrap();
        index.close_open_focus_interval(3000).unwrap();

        // Point query within Chrome's interval
        let ctx = index.find_app_at_timestamp(1500).unwrap();
        assert!(ctx.is_some());
        let ctx = ctx.unwrap();
        assert_eq!(ctx.app_name, "Chrome");
        assert_eq!(ctx.bundle_id, Some("com.google.Chrome".to_string()));

        // Point query within VS Code's interval
        let ctx = index.find_app_at_timestamp(2500).unwrap();
        assert!(ctx.is_some());
        assert_eq!(ctx.unwrap().app_name, "VS Code");

        // Point query at exact boundary (start_ts = 2000 should be VS Code, not Chrome)
        let ctx = index.find_app_at_timestamp(2000).unwrap();
        assert!(ctx.is_some());
        assert_eq!(ctx.unwrap().app_name, "VS Code");

        // Point query before any interval — no result
        let ctx = index.find_app_at_timestamp(500).unwrap();
        assert!(ctx.is_none());

        // Point query after all intervals — no result
        let ctx = index.find_app_at_timestamp(3500).unwrap();
        assert!(ctx.is_none());
    }

    #[test]
    fn test_insert_records_focus_intervals() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Insert an app_switch event — should auto-record focus interval
        let header = EventHeader {
            ts: 1000,
            track: 3,
            r#type: Some("app_switch".into()),
            app_name: Some("Chrome".into()),
            window_title: Some("Gmail".into()),
            url: None,
            v: None,
            ts_wall_us: None,
            ts_mono_ns: None,
            seq: None,
            session_id: None,
            source: None,
            display_id: None,
            pid: None,
            bundle_id: Some("com.google.Chrome".into()),
            ax_role: None,
            ax_title: None,
            ax_identifier: None,
            click_x: None,
            click_y: None,
        };

        index.insert(&header, "seg1.msgpack", None).unwrap();

        // Second app switch closes Chrome, opens VS Code
        let header2 = EventHeader {
            ts: 2000,
            track: 3,
            r#type: Some("app_switch".into()),
            app_name: Some("VS Code".into()),
            window_title: Some("main.rs".into()),
            url: None,
            v: None,
            ts_wall_us: None,
            ts_mono_ns: None,
            seq: None,
            session_id: None,
            source: None,
            display_id: None,
            pid: None,
            bundle_id: Some("com.microsoft.VSCode".into()),
            ax_role: None,
            ax_title: None,
            ax_identifier: None,
            click_x: None,
            click_y: None,
        };

        index.insert(&header2, "seg1.msgpack", None).unwrap();

        let blocks = index.query_focus_intervals(0, 3000).unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].app_name, "Chrome");
        assert_eq!(blocks[0].end_ts, 2000);
        assert_eq!(blocks[1].app_name, "VS Code");
        // VS Code is still open (end_ts = 0 → clamped to query end)
        assert_eq!(blocks[1].end_ts, 3000);
    }

    #[test]
    fn test_audio_segment_lifecycle() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Insert audio segment
        let seg_id = index
            .insert_audio_segment("mic", 1000, "/audio/mic_001.m4a", None, Some(48000), Some(1))
            .unwrap();
        assert!(seg_id > 0);

        // Query within range
        let seg = index.find_audio_segment("mic", 1500).unwrap();
        assert!(seg.is_some());
        let seg = seg.unwrap();
        assert_eq!(seg.source, "mic");
        assert_eq!(seg.sample_rate, Some(48000));

        // Finalize
        index
            .finalize_audio_segment("/audio/mic_001.m4a", 2000)
            .unwrap();

        // Query in gap after finalization
        let seg = index.find_audio_segment("mic", 2500).unwrap();
        assert!(seg.is_none());

        // Verify unified segments table was updated
        let status: String = index
            .conn
            .query_row(
                "SELECT status FROM segments WHERE kind = 'audio' AND path = ?1",
                params!["/audio/mic_001.m4a"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "sealed");
    }

    #[test]
    fn test_finalize_orphan_audio_segments() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Insert two audio segments (simulate crash — end_ts stays 0)
        index
            .insert_audio_segment("mic", 1000, "/audio/orphan_1.m4a", None, Some(48000), Some(1))
            .unwrap();
        index
            .insert_audio_segment("mic", 2000, "/audio/orphan_2.m4a", None, Some(48000), Some(1))
            .unwrap();

        // Also insert a properly finalized segment
        index
            .insert_audio_segment("mic", 3000, "/audio/finalized.m4a", None, Some(48000), Some(1))
            .unwrap();
        index
            .finalize_audio_segment("/audio/finalized.m4a", 4000)
            .unwrap();

        // Finalize orphans
        let count = index.finalize_orphan_audio_segments(5000).unwrap();
        assert_eq!(count, 2, "Should finalize exactly 2 orphan segments");

        // Verify orphans now have end_ts set
        let seg1 = index.find_audio_segment("mic", 1500).unwrap();
        assert!(seg1.is_some());
        assert_eq!(seg1.unwrap().end_ts, 5000);

        // Running again should find 0 orphans
        let count2 = index.finalize_orphan_audio_segments(6000).unwrap();
        assert_eq!(count2, 0, "No orphans should remain");

        // Verify unified segments table status
        let status: String = index
            .conn
            .query_row(
                "SELECT status FROM segments WHERE kind = 'audio' AND path = ?1",
                params!["/audio/orphan_1.m4a"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "sealed");
    }

    #[test]
    fn test_query_resolves_segment_path_through_segments_table() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Register a segment with a raw path
        let seg_id = index
            .resolve_event_segment("/path/to/hour14.msgpack", 1000000)
            .unwrap();

        // Insert an event referencing this segment
        let header = EventHeader {
            ts: 1000000, track: 2, r#type: Some("key_down".into()),
            app_name: Some("Chrome".into()), window_title: None, url: None,
            v: Some(2), ts_wall_us: Some(1000000), ts_mono_ns: Some(100),
            seq: Some(1), session_id: Some("s1".into()), source: Some("input_monitor".into()),
            display_id: None, pid: None, bundle_id: None,
            ax_role: None, ax_title: None, ax_identifier: None, click_x: None, click_y: None,
        };
        index.insert(&header, "/path/to/hour14.msgpack", Some(seg_id)).unwrap();

        // Simulate compression: update segments table path (like rotation does)
        index.update_segment(
            seg_id, "sealed", Some(2000000),
            Some("/path/to/hour14.msgpack.zst"), Some("zstd"),
        ).unwrap();

        // Query should resolve the compressed path through segments table
        let results = index.query_range(0, 2000000).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].segment_file, "/path/to/hour14.msgpack.zst");
    }

    #[test]
    fn test_integrity_check() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Register segment and insert events
        let seg_id = index.resolve_event_segment("/path/to/seg.msgpack", 1000).unwrap();
        let header = EventHeader {
            ts: 1000, track: 2, r#type: Some("key_down".into()),
            app_name: Some("Chrome".into()), window_title: None, url: None,
            v: Some(2), ts_wall_us: Some(1000), ts_mono_ns: Some(100),
            seq: Some(1), session_id: Some("s1".into()), source: Some("input_monitor".into()),
            display_id: None, pid: None, bundle_id: None,
            ax_role: None, ax_title: None, ax_identifier: None, click_x: None, click_y: None,
        };
        index.insert(&header, "/path/to/seg.msgpack", Some(seg_id)).unwrap();

        let report = index.check_segment_integrity().unwrap();
        assert_eq!(report.stale_segment_refs, 0);
        assert_eq!(report.total_events, 1);
        assert_eq!(report.events_with_segment_id, 1);
        assert!(report.segments_count >= 1);
        assert_eq!(report.ordering_violations, 0);
    }

    #[test]
    fn test_migration_idempotent() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        // Open twice — migrations should be idempotent
        let _index1 = TimelineIndex::new(&paths).unwrap();
        let _index2 = TimelineIndex::new(&paths).unwrap();
    }

    #[test]
    fn test_list_audio_segments_in_range() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Sealed segment within range: start=1000, end=3000
        index
            .insert_audio_segment("mic", 1000, "/audio/sealed_in_range.m4a", None, Some(48000), Some(1))
            .unwrap();
        index
            .finalize_audio_segment("/audio/sealed_in_range.m4a", 3000)
            .unwrap();

        // Active segment (end_ts = 0) — should be excluded
        index
            .insert_audio_segment("mic", 2000, "/audio/active.m4a", None, Some(48000), Some(1))
            .unwrap();
        // Not finalized — end_ts stays 0

        // Sealed segment outside range: start=5000, end=7000
        index
            .insert_audio_segment("system", 5000, "/audio/sealed_out_range.m4a", None, Some(48000), Some(2))
            .unwrap();
        index
            .finalize_audio_segment("/audio/sealed_out_range.m4a", 7000)
            .unwrap();

        // Query range 500..4000 — should only return the sealed in-range segment
        let results = index.list_audio_segments_in_range(500, 4000).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].file_path, "/audio/sealed_in_range.m4a");
        assert_eq!(results[0].source, "mic");
        assert_eq!(results[0].start_ts, 1000);
        assert_eq!(results[0].end_ts, 3000);

        // Query range 4000..8000 — should only return the out-of-range sealed segment
        let results = index.list_audio_segments_in_range(4000, 8000).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].file_path, "/audio/sealed_out_range.m4a");

        // Query range 0..10000 — should return both sealed segments, not the active one
        let results = index.list_audio_segments_in_range(0, 10000).unwrap();
        assert_eq!(results.len(), 2);

        // Query range entirely outside all segments — should return nothing
        let results = index.list_audio_segments_in_range(8000, 9000).unwrap();
        assert_eq!(results.len(), 0);
    }

    #[test]
    fn test_list_audio_segments_after_checkpoint() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Insert and finalize segments
        let id1 = index
            .insert_audio_segment("mic", 1000, "/a1.m4a", None, Some(48000), Some(1))
            .unwrap();
        index.finalize_audio_segment("/a1.m4a", 2000).unwrap();

        let id2 = index
            .insert_audio_segment("system", 1000, "/a2.m4a", None, Some(48000), Some(2))
            .unwrap();
        index.finalize_audio_segment("/a2.m4a", 2000).unwrap();

        let id3 = index
            .insert_audio_segment("mic", 3000, "/a3.m4a", None, Some(48000), Some(1))
            .unwrap();
        index.finalize_audio_segment("/a3.m4a", 4000).unwrap();

        // Also insert an active segment — should NOT appear (end_ts = 0)
        let _id_active = index
            .insert_audio_segment("mic", 5000, "/a_active.m4a", None, Some(48000), Some(1))
            .unwrap();

        // Checkpoint = 0 → get all sealed
        let segs = index.list_audio_segments_after_checkpoint(0, 10).unwrap();
        assert_eq!(segs.len(), 3);
        assert_eq!(segs[0].segment_id, id1);
        assert_eq!(segs[1].segment_id, id2);
        assert_eq!(segs[2].segment_id, id3);

        // Checkpoint = id1 → get id2 and id3
        let segs = index.list_audio_segments_after_checkpoint(id1, 10).unwrap();
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0].segment_id, id2);
        assert_eq!(segs[1].segment_id, id3);

        // Checkpoint = id3 → get nothing
        let segs = index.list_audio_segments_after_checkpoint(id3, 10).unwrap();
        assert_eq!(segs.len(), 0);
    }

    #[test]
    fn test_list_audio_segments_checkpoint_overlap() {
        // Verify overlapping mic/system segments with identical timestamps
        // don't cause skips when using segment_id-based pagination
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Overlapping segments (same time range, different sources — typical for calls)
        let id_mic = index
            .insert_audio_segment("mic", 1000, "/mic1.m4a", None, Some(48000), Some(1))
            .unwrap();
        index.finalize_audio_segment("/mic1.m4a", 3000).unwrap();

        let id_sys = index
            .insert_audio_segment("system", 1000, "/sys1.m4a", None, Some(48000), Some(2))
            .unwrap();
        index.finalize_audio_segment("/sys1.m4a", 3000).unwrap();

        // Batch limit = 1: process mic first
        let segs = index.list_audio_segments_after_checkpoint(0, 1).unwrap();
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].segment_id, id_mic);

        // Checkpoint = id_mic → must get system segment (not skip it!)
        let segs = index.list_audio_segments_after_checkpoint(id_mic, 1).unwrap();
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].segment_id, id_sys);
        assert_eq!(segs[0].source, "system");

        // Checkpoint = id_sys → empty
        let segs = index.list_audio_segments_after_checkpoint(id_sys, 10).unwrap();
        assert_eq!(segs.len(), 0);
    }

    #[test]
    fn test_list_audio_segments_checkpoint_batch_truncation() {
        // Verify batch truncation doesn't lose data on restart
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Create 5 segments
        let mut ids = Vec::new();
        for i in 0u64..5 {
            let id = index
                .insert_audio_segment(
                    if i % 2 == 0 { "mic" } else { "system" },
                    i * 1000 + 1000,
                    &format!("/seg{}.m4a", i),
                    None,
                    Some(48000),
                    Some(1),
                )
                .unwrap();
            index
                .finalize_audio_segment(&format!("/seg{}.m4a", i), i * 1000 + 2000)
                .unwrap();
            ids.push(id);
        }

        // Process in batches of 2
        let batch1 = index.list_audio_segments_after_checkpoint(0, 2).unwrap();
        assert_eq!(batch1.len(), 2);
        let cp1 = batch1.last().unwrap().segment_id;

        let batch2 = index.list_audio_segments_after_checkpoint(cp1, 2).unwrap();
        assert_eq!(batch2.len(), 2);
        let cp2 = batch2.last().unwrap().segment_id;

        let batch3 = index.list_audio_segments_after_checkpoint(cp2, 2).unwrap();
        assert_eq!(batch3.len(), 1); // Only one left

        let batch4 = index
            .list_audio_segments_after_checkpoint(batch3[0].segment_id, 2)
            .unwrap();
        assert_eq!(batch4.len(), 0); // Done

        // Verify all 5 segments were returned across all batches
        let all_ids: Vec<i64> = [batch1, batch2, batch3]
            .iter()
            .flatten()
            .map(|s| s.segment_id)
            .collect();
        assert_eq!(all_ids, ids);
    }

    #[test]
    fn test_visual_change_log() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let index = TimelineIndex::new(&paths).unwrap();

        // Record several changes across two displays
        index.record_visual_change(1, 1000000, 0.5).unwrap();
        index.record_visual_change(1, 2000000, 0.1).unwrap();
        index.record_visual_change(1, 3000000, 0.8).unwrap();
        index.record_visual_change(2, 1500000, 0.6).unwrap();

        // Query with threshold 0.3 — should only get distances > 0.3
        let results = index.query_visual_changes(1, 0, 4000000, 0.3).unwrap();
        assert_eq!(results, vec![1000000, 3000000]);

        // Different display
        let results = index.query_visual_changes(2, 0, 4000000, 0.3).unwrap();
        assert_eq!(results, vec![1500000]);

        // Empty range
        let results = index.query_visual_changes(1, 5000000, 6000000, 0.3).unwrap();
        assert!(results.is_empty());

        // Upsert: same key should update distance
        index.record_visual_change(1, 1000000, 0.2).unwrap();
        let results = index.query_visual_changes(1, 0, 4000000, 0.3).unwrap();
        assert_eq!(results, vec![3000000]); // 1000000 now has distance 0.2, below threshold
    }

    /// Proves: if the transcript worker does NOT advance the checkpoint after a transient
    /// failure, the same segment is returned on the next query. This is the core invariant
    /// that prevents permanent data loss from transient speech recognition errors.
    ///
    /// Scenario: two sealed segments. Worker processes segment 1, transcription fails.
    /// Worker does NOT call set_checkpoint. Next cycle, query returns segment 1 again.
    /// Worker retries, succeeds, advances checkpoint. Segment 2 is now returned.
    #[test]
    fn test_checkpoint_no_advance_retries_same_segment() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();

        let mut index = TimelineIndex::new(&paths).unwrap();

        // Insert two sealed segments
        let id1 = index
            .insert_audio_segment("mic", 1000, "/retry_a.m4a", None, None, None)
            .unwrap();
        index.finalize_audio_segment("/retry_a.m4a", 2000).unwrap();

        let id2 = index
            .insert_audio_segment("system", 1500, "/retry_b.m4a", None, None, None)
            .unwrap();
        index.finalize_audio_segment("/retry_b.m4a", 2500).unwrap();

        // Cycle 1: query from checkpoint 0 — returns both segments
        let batch1 = index.list_audio_segments_after_checkpoint(0, 10).unwrap();
        assert_eq!(batch1.len(), 2);
        assert_eq!(batch1[0].segment_id, id1);
        assert_eq!(batch1[1].segment_id, id2);

        // Simulate: segment 1 transcription fails. Checkpoint NOT advanced (still 0).
        // Cycle 2: query from same checkpoint — returns SAME segments for retry.
        let batch2 = index.list_audio_segments_after_checkpoint(0, 10).unwrap();
        assert_eq!(batch2.len(), 2);
        assert_eq!(batch2[0].segment_id, id1); // segment 1 returned again for retry

        // Simulate: segment 1 succeeds on retry. Checkpoint advanced to id1.
        // Cycle 3: query from id1 — only segment 2 remains.
        let batch3 = index
            .list_audio_segments_after_checkpoint(id1, 10)
            .unwrap();
        assert_eq!(batch3.len(), 1);
        assert_eq!(batch3[0].segment_id, id2);

        // Simulate: segment 2 succeeds. Checkpoint advanced to id2.
        // Cycle 4: query from id2 — empty, all processed.
        let batch4 = index
            .list_audio_segments_after_checkpoint(id2, 10)
            .unwrap();
        assert_eq!(batch4.len(), 0);
    }

    #[test]
    fn test_retention_tier_columns() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let mut index = TimelineIndex::new(&paths).unwrap();

        // Insert a video segment
        index
            .insert_video_segment(1, 1000000, "/tmp/test.mp4")
            .unwrap();
        index
            .finalize_video_segment("/tmp/test.mp4", 2000000)
            .unwrap();

        // Default tier should be 'hot'
        let segments = index
            .list_video_segments_for_retention("hot", 3000000)
            .unwrap();
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].file_path, "/tmp/test.mp4");

        // Update tier
        index
            .update_video_segment_tier("/tmp/test.mp4", "warm")
            .unwrap();
        let hot = index
            .list_video_segments_for_retention("hot", 3000000)
            .unwrap();
        assert!(hot.is_empty());
        let warm = index
            .list_video_segments_for_retention("warm", 3000000)
            .unwrap();
        assert_eq!(warm.len(), 1);

        // Find by path
        let found = index.find_video_segment_by_path("/tmp/test.mp4").unwrap();
        assert!(found.is_some());
        let not_found = index.find_video_segment_by_path("/tmp/nope.mp4").unwrap();
        assert!(not_found.is_none());
    }

    #[test]
    fn test_keyframes_crud() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        // Insert keyframes
        index
            .insert_keyframe(1, 1000000, "/kf/a.jpg", "/video/seg1.mp4", Some(5000))
            .unwrap();
        index
            .insert_keyframe(1, 2000000, "/kf/b.jpg", "/video/seg1.mp4", Some(6000))
            .unwrap();
        index
            .insert_keyframe(1, 3000000, "/kf/c.jpg", "/video/seg2.mp4", Some(7000))
            .unwrap();

        // Idempotent insert (same file_path)
        index
            .insert_keyframe(1, 1000000, "/kf/a.jpg", "/video/seg1.mp4", Some(5000))
            .unwrap();

        // Find nearest — 1500000 is equidistant from a.jpg (1000000) and b.jpg (2000000),
        // should pick the earlier one (before wins on tie)
        let nearest = index.find_nearest_keyframe(1, 1500000).unwrap();
        assert!(nearest.is_some());
        assert_eq!(nearest.unwrap(), "/kf/a.jpg");

        // Find nearest outside 1-hour bound (all keyframes are at 1M, 2M, 3M;
        // query at 3M + 3.6B + 1 = 3_603_000_001 which is > 1 hour from any keyframe)
        let far = index
            .find_nearest_keyframe(1, 3_000_000 + 3_600_000_001)
            .unwrap();
        assert!(far.is_none());

        // List for segment
        let paths = index
            .list_keyframe_paths_for_segment("/video/seg1.mp4")
            .unwrap();
        assert_eq!(paths.len(), 2);

        // Delete for segment
        let deleted = index
            .delete_keyframe_rows_for_segment("/video/seg1.mp4")
            .unwrap();
        assert_eq!(deleted, 2);

        // Remaining
        let paths = index
            .list_keyframe_paths_for_segment("/video/seg2.mp4")
            .unwrap();
        assert_eq!(paths.len(), 1);
    }

    #[test]
    fn test_register_keyframes_does_not_set_tier() {
        // Verify that inserting keyframe rows does NOT update the video segment's
        // retention_tier. The tier should only be updated by the Swift caller
        // after successful video file deletion.
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let mut index = TimelineIndex::new(&paths).unwrap();

        // Create and finalize a video segment
        index
            .insert_video_segment(1, 1_000_000, "/tmp/test_seg.mp4")
            .unwrap();
        index
            .finalize_video_segment("/tmp/test_seg.mp4", 4_600_000_000)
            .unwrap();

        // Verify segment starts as 'hot'
        let hot_segs = index
            .list_video_segments_for_retention("hot", 5_000_000_000)
            .unwrap();
        assert_eq!(hot_segs.len(), 1);

        // Insert keyframes (simulating what register_keyframes does — just the inserts, no tier change)
        index
            .insert_keyframe(1, 1_000_000, "/kf/a.jpg", "/tmp/test_seg.mp4", Some(5000))
            .unwrap();
        index
            .insert_keyframe(1, 2_000_000, "/kf/b.jpg", "/tmp/test_seg.mp4", Some(6000))
            .unwrap();

        // After inserting keyframes, the segment should STILL be 'hot'
        let hot_segs = index
            .list_video_segments_for_retention("hot", 5_000_000_000)
            .unwrap();
        assert_eq!(
            hot_segs.len(),
            1,
            "Segment should still be hot after keyframe insertion"
        );

        // Only after explicit tier update should it become 'warm'
        index
            .update_video_segment_tier("/tmp/test_seg.mp4", "warm")
            .unwrap();
        let hot_segs = index
            .list_video_segments_for_retention("hot", 5_000_000_000)
            .unwrap();
        assert!(
            hot_segs.is_empty(),
            "Segment should no longer be hot"
        );
        let warm_segs = index
            .list_video_segments_for_retention("warm", 5_000_000_000)
            .unwrap();
        assert_eq!(
            warm_segs.len(),
            1,
            "Segment should now be warm"
        );
    }

    // --- Semantic Knowledge CRUD Tests ---

    #[test]
    fn test_semantic_knowledge_upsert_and_query() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_semantic_knowledge(
                "sk-1", "preference", "theme", "dark mode preferred", 0.85,
                "ep-1,ep-2", 1000000, 1000000,
            )
            .unwrap();

        let results = index.query_semantic_knowledge(Some("preference"), 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, "sk-1");
        assert_eq!(results[0].category, "preference");
        assert_eq!(results[0].key, "theme");
        assert_eq!(results[0].value, "dark mode preferred");
        assert!((results[0].confidence - 0.85).abs() < 0.001);
        assert_eq!(results[0].access_count, 0);
    }

    #[test]
    fn test_semantic_knowledge_upsert_replaces() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_semantic_knowledge(
                "sk-1", "preference", "theme", "dark mode", 0.6,
                "ep-1", 1000000, 1000000,
            )
            .unwrap();
        index
            .upsert_semantic_knowledge(
                "sk-1", "preference", "theme", "light mode actually", 0.9,
                "ep-1,ep-3", 1000000, 2000000,
            )
            .unwrap();

        let results = index.query_semantic_knowledge(Some("preference"), 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].value, "light mode actually");
        assert!((results[0].confidence - 0.9).abs() < 0.001);
    }

    #[test]
    fn test_semantic_knowledge_query_all() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_semantic_knowledge(
                "sk-1", "preference", "theme", "dark", 0.8,
                "ep-1", 1000000, 1000000,
            )
            .unwrap();
        index
            .upsert_semantic_knowledge(
                "sk-2", "fact", "editor", "uses VS Code", 0.95,
                "ep-2", 2000000, 2000000,
            )
            .unwrap();

        // Query without category filter
        let results = index.query_semantic_knowledge(None, 10).unwrap();
        assert_eq!(results.len(), 2);
        // Ordered by updated_at DESC
        assert_eq!(results[0].id, "sk-2");
        assert_eq!(results[1].id, "sk-1");
    }

    #[test]
    fn test_semantic_knowledge_touch() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_semantic_knowledge(
                "sk-1", "preference", "font", "Monaco", 0.7,
                "ep-1", 1000000, 1000000,
            )
            .unwrap();

        index.touch_semantic_knowledge("sk-1", 5000000).unwrap();
        index.touch_semantic_knowledge("sk-1", 6000000).unwrap();

        let results = index.query_semantic_knowledge(Some("preference"), 10).unwrap();
        assert_eq!(results[0].access_count, 2);
        assert_eq!(results[0].last_accessed_at, Some(6000000));
    }

    #[test]
    fn test_semantic_knowledge_delete() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_semantic_knowledge(
                "sk-1", "preference", "theme", "dark", 0.8,
                "ep-1", 1000000, 1000000,
            )
            .unwrap();

        index.delete_semantic_knowledge("sk-1").unwrap();

        let results = index.query_semantic_knowledge(Some("preference"), 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_semantic_knowledge_query_limit() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        for i in 0..5 {
            index
                .upsert_semantic_knowledge(
                    &format!("sk-{}", i), "preference", &format!("key-{}", i),
                    "value", 0.8, "ep-1", 1000000, 1000000 + i * 1000,
                )
                .unwrap();
        }

        let results = index.query_semantic_knowledge(Some("preference"), 3).unwrap();
        assert_eq!(results.len(), 3);
    }

    // --- Directives CRUD Tests ---

    #[test]
    fn test_directive_upsert_and_query() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_directive(
                "dir-1", "reminder", "opens Slack", "Check standup channel",
                5, 1000000, Some(9000000), "user request",
            )
            .unwrap();

        let results = index.query_active_directives(2000000, 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, "dir-1");
        assert_eq!(results[0].directive_type, "reminder");
        assert_eq!(results[0].trigger_pattern, "opens Slack");
        assert_eq!(results[0].action_description, "Check standup channel");
        assert_eq!(results[0].priority, 5);
        assert!(results[0].is_active);
        assert_eq!(results[0].execution_count, 0);
    }

    #[test]
    fn test_directive_expires() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_directive(
                "dir-1", "reminder", "trigger", "action",
                5, 1000000, Some(5000000), "test",
            )
            .unwrap();

        // Before expiry
        let results = index.query_active_directives(3000000, 10).unwrap();
        assert_eq!(results.len(), 1);

        // After expiry
        let results = index.query_active_directives(6000000, 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_directive_no_expiry() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_directive(
                "dir-1", "habit", "any", "action",
                3, 1000000, None, "test",
            )
            .unwrap();

        // Should never expire
        let results = index.query_active_directives(999_999_999_999, 10).unwrap();
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn test_directive_record_trigger() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_directive(
                "dir-1", "reminder", "trigger", "action",
                5, 1000000, None, "test",
            )
            .unwrap();

        index.record_directive_trigger("dir-1", 2000000).unwrap();
        index.record_directive_trigger("dir-1", 3000000).unwrap();

        let results = index.query_active_directives(1500000, 10).unwrap();
        assert_eq!(results[0].execution_count, 2);
        assert_eq!(results[0].last_triggered_at, Some(3000000));
    }

    #[test]
    fn test_directive_deactivate() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_directive(
                "dir-1", "reminder", "trigger", "action",
                5, 1000000, None, "test",
            )
            .unwrap();

        index.deactivate_directive("dir-1").unwrap();

        let results = index.query_active_directives(1500000, 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_directive_delete() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_directive(
                "dir-1", "reminder", "trigger", "action",
                5, 1000000, None, "test",
            )
            .unwrap();

        index.delete_directive("dir-1").unwrap();

        let results = index.query_active_directives(1500000, 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_directive_priority_ordering() {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        let index = TimelineIndex::new(&paths).unwrap();

        index
            .upsert_directive("dir-low", "reminder", "t1", "low", 1, 1000000, None, "test")
            .unwrap();
        index
            .upsert_directive("dir-high", "reminder", "t2", "high", 10, 2000000, None, "test")
            .unwrap();
        index
            .upsert_directive("dir-mid", "reminder", "t3", "mid", 5, 3000000, None, "test")
            .unwrap();

        let results = index.query_active_directives(500000, 10).unwrap();
        assert_eq!(results.len(), 3);
        // Priority DESC
        assert_eq!(results[0].id, "dir-high");
        assert_eq!(results[1].id, "dir-mid");
        assert_eq!(results[2].id, "dir-low");
    }
}
