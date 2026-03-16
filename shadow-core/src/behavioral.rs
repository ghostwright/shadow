use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

/// A single recorded user interaction, enriched with AX context.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct BehavioralAction {
    pub ts: u64,
    pub action_type: String,
    pub ax_role: Option<String>,
    pub ax_title: Option<String>,
    pub ax_identifier: Option<String>,
    pub x: Option<i32>,
    pub y: Option<i32>,
    pub key_chars: Option<String>,
}

/// A sequence of user interactions within a single app context.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct BehavioralSequence {
    pub start_ts: u64,
    pub end_ts: u64,
    pub app_name: String,
    pub window_title: String,
    pub actions: Vec<BehavioralAction>,
}

/// Summary of interaction frequency with a specific AX element.
/// Used by the `top_app_interactions` UniFFI export.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct InteractionSummary {
    pub ax_role: String,
    pub ax_title: String,
    pub count: u64,
}

/// Maximum gap between actions before starting a new sequence (5 seconds).
const SEQUENCE_GAP_US: u64 = 5_000_000;

/// Maximum number of actions per sequence.
const MAX_ACTIONS_PER_SEQUENCE: usize = 50;

/// Search for past interaction sequences matching an app and optional query.
///
/// Strategy:
/// 1. Find time ranges where the target app was focused (from app_focus_intervals)
/// 2. Within those ranges, fetch enriched input events (track=2 in events_index)
/// 3. Group into sequences (gap > 5s = new sequence)
/// 4. Filter and rank by relevance to the query
///
/// Returns up to `max_results` sequences, most recent first.
pub fn search_behavioral_context(
    conn: &Connection,
    query: &str,
    target_app: &str,
    max_results: u32,
) -> Result<Vec<BehavioralSequence>, String> {
    // Step 1: Find recent focus intervals for the target app (last 7 days)
    let now_us = wall_micros();
    let lookback_us = 7 * 24 * 3600 * 1_000_000u64;
    let start_ts = now_us.saturating_sub(lookback_us);

    let mut stmt = conn
        .prepare(
            "SELECT start_ts, end_ts, app_name
             FROM app_focus_intervals
             WHERE app_name LIKE ?1
               AND start_ts >= ?2
             ORDER BY start_ts DESC
             LIMIT 100",
        )
        .map_err(|e| format!("Failed to prepare focus query: {e}"))?;

    let intervals: Vec<(u64, u64, String)> = stmt
        .query_map(params![format!("%{}%", target_app), start_ts as i64], |row| {
            let s: i64 = row.get(0)?;
            let e: i64 = row.get(1)?;
            let app: String = row.get(2)?;
            Ok((s as u64, if e > 0 { e as u64 } else { now_us }, app))
        })
        .map_err(|e| format!("Focus query failed: {e}"))?
        .filter_map(|r| r.ok())
        .collect();

    if intervals.is_empty() {
        return Ok(vec![]);
    }

    // Step 2: For each interval, fetch enriched input events
    let query_words: Vec<String> = query
        .to_lowercase()
        .split_whitespace()
        .map(String::from)
        .collect();

    let mut all_sequences: Vec<BehavioralSequence> = Vec::new();

    let mut event_stmt = conn
        .prepare(
            "SELECT ts, event_type, ax_role, ax_title, ax_identifier,
                    click_x, click_y, window_title
             FROM events_index
             WHERE track = 2
               AND ts >= ?1 AND ts <= ?2
               AND event_type IN ('mouse_down', 'key_down', 'scroll')
             ORDER BY ts ASC
             LIMIT 500",
        )
        .map_err(|e| format!("Failed to prepare event query: {e}"))?;

    for (interval_start, interval_end, app_name) in &intervals {
        let actions: Vec<(BehavioralAction, Option<String>)> = event_stmt
            .query_map(params![*interval_start as i64, *interval_end as i64], |row| {
                let ts: i64 = row.get(0)?;
                let action_type: String = row.get(1)?;
                let ax_role: Option<String> = row.get(2)?;
                let ax_title: Option<String> = row.get(3)?;
                let ax_identifier: Option<String> = row.get(4)?;
                let click_x: Option<i32> = row.get(5)?;
                let click_y: Option<i32> = row.get(6)?;
                let window_title: Option<String> = row.get(7)?;
                Ok((
                    BehavioralAction {
                        ts: ts as u64,
                        action_type,
                        ax_role,
                        ax_title,
                        ax_identifier,
                        x: click_x,
                        y: click_y,
                        key_chars: None,
                    },
                    window_title,
                ))
            })
            .map_err(|e| format!("Event query failed: {e}"))?
            .filter_map(|r| r.ok())
            .collect();

        if actions.is_empty() {
            continue;
        }

        // Step 3: Group into sequences by time gap
        let mut current_seq: Vec<BehavioralAction> = Vec::new();
        let mut current_title = String::new();
        let mut seq_start = 0u64;

        for (action, win_title) in &actions {
            if !current_seq.is_empty()
                && action.ts.saturating_sub(current_seq.last().unwrap().ts) > SEQUENCE_GAP_US
            {
                // Finish current sequence
                if current_seq.len() >= 2 {
                    all_sequences.push(BehavioralSequence {
                        start_ts: seq_start,
                        end_ts: current_seq.last().unwrap().ts,
                        app_name: app_name.clone(),
                        window_title: current_title.clone(),
                        actions: current_seq.clone(),
                    });
                }
                current_seq.clear();
            }

            if current_seq.is_empty() {
                seq_start = action.ts;
                current_title = win_title.clone().unwrap_or_default();
            }

            current_seq.push(action.clone());
            if current_seq.len() >= MAX_ACTIONS_PER_SEQUENCE {
                all_sequences.push(BehavioralSequence {
                    start_ts: seq_start,
                    end_ts: current_seq.last().unwrap().ts,
                    app_name: app_name.clone(),
                    window_title: current_title.clone(),
                    actions: current_seq.clone(),
                });
                current_seq.clear();
            }
        }

        // Flush remaining
        if current_seq.len() >= 2 {
            all_sequences.push(BehavioralSequence {
                start_ts: seq_start,
                end_ts: current_seq.last().unwrap().ts,
                app_name: app_name.clone(),
                window_title: current_title.clone(),
                actions: current_seq,
            });
        }
    }

    // Step 4: Rank by relevance
    if !query_words.is_empty() {
        all_sequences.sort_by(|a, b| {
            let score_a = relevance_score(a, &query_words);
            let score_b = relevance_score(b, &query_words);
            score_b
                .partial_cmp(&score_a)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
    }

    // Return most recent first (after relevance sort)
    all_sequences.truncate(max_results as usize);
    Ok(all_sequences)
}

/// Score a behavioral sequence for relevance to query words.
fn relevance_score(seq: &BehavioralSequence, query_words: &[String]) -> f64 {
    let mut score = 0.0;

    let title_lower = seq.window_title.to_lowercase();
    for word in query_words {
        if title_lower.contains(word.as_str()) {
            score += 1.0;
        }
    }

    // Bonus for sequences with AX-enriched actions
    let enriched_count = seq
        .actions
        .iter()
        .filter(|a| a.ax_role.is_some())
        .count();
    if enriched_count > 0 {
        score += 0.5;
    }

    // Bonus for AX title matches
    for action in &seq.actions {
        if let Some(ref ax_title) = action.ax_title {
            let ax_lower = ax_title.to_lowercase();
            for word in query_words {
                if ax_lower.contains(word.as_str()) {
                    score += 0.3;
                }
            }
        }
    }

    // Recency bonus (more recent = higher score)
    let now = wall_micros();
    let age_hours = (now.saturating_sub(seq.end_ts)) as f64 / 3_600_000_000.0;
    if age_hours < 1.0 {
        score += 0.5;
    } else if age_hours < 24.0 {
        score += 0.2;
    }

    score
}

/// Get current wall time in microseconds.
fn wall_micros() -> u64 {
    let now = std::time::SystemTime::now();
    now.duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
}

/// Query the count of AX-enriched mouse_down events in a time range.
/// Used for diagnostics and progress tracking.
pub fn count_enriched_clicks(
    conn: &Connection,
    start_us: u64,
    end_us: u64,
) -> Result<u64, String> {
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM events_index
             WHERE track = 2 AND event_type = 'mouse_down'
               AND ax_role IS NOT NULL
               AND ts >= ?1 AND ts <= ?2",
            params![start_us as i64, end_us as i64],
            |row| row.get(0),
        )
        .map_err(|e| format!("Count query failed: {e}"))?;
    Ok(count as u64)
}

/// Find the most common AX element interaction patterns for an app.
/// Returns (ax_role, ax_title, count) tuples, most frequent first.
pub fn top_interactions(
    conn: &Connection,
    app_name: &str,
    limit: u32,
) -> Result<Vec<(String, String, u64)>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT ax_role, ax_title, COUNT(*) as cnt
             FROM events_index
             WHERE track = 2
               AND event_type = 'mouse_down'
               AND ax_role IS NOT NULL
               AND app_name LIKE ?1
             GROUP BY ax_role, ax_title
             ORDER BY cnt DESC
             LIMIT ?2",
        )
        .map_err(|e| format!("Failed to prepare top interactions query: {e}"))?;

    let results: Vec<(String, String, u64)> = stmt
        .query_map(params![format!("%{}%", app_name), limit], |row| {
            let role: String = row.get(0)?;
            let title: String = row.get::<_, Option<String>>(1)?.unwrap_or_default();
            let count: i64 = row.get(2)?;
            Ok((role, title, count as u64))
        })
        .map_err(|e| format!("Top interactions query failed: {e}"))?
        .filter_map(|r| r.ok())
        .collect();

    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn setup_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE events_index (
                ts INTEGER NOT NULL,
                track INTEGER NOT NULL,
                event_type TEXT NOT NULL DEFAULT '',
                app_name TEXT,
                window_title TEXT,
                url TEXT,
                segment_file TEXT NOT NULL DEFAULT '',
                seq INTEGER,
                session_id TEXT,
                display_id INTEGER,
                pid INTEGER,
                bundle_id TEXT,
                segment_id INTEGER,
                ax_role TEXT,
                ax_title TEXT,
                ax_identifier TEXT,
                click_x INTEGER,
                click_y INTEGER
            );
            CREATE TABLE app_focus_intervals (
                id INTEGER PRIMARY KEY,
                app_name TEXT NOT NULL,
                bundle_id TEXT,
                start_ts INTEGER NOT NULL,
                end_ts INTEGER NOT NULL DEFAULT 0,
                display_id INTEGER,
                session_id TEXT
            );",
        )
        .unwrap();
        conn
    }

    #[test]
    fn test_search_empty_db() {
        let conn = setup_test_db();
        let results = search_behavioral_context(&conn, "send email", "Gmail", 5).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_with_enriched_events() {
        let conn = setup_test_db();

        // Insert a focus interval for Chrome
        let now = wall_micros();
        let interval_start = now - 3_600_000_000; // 1 hour ago
        conn.execute(
            "INSERT INTO app_focus_intervals (app_name, bundle_id, start_ts, end_ts)
             VALUES ('Google Chrome', 'com.google.Chrome', ?1, ?2)",
            params![interval_start as i64, now as i64],
        )
        .unwrap();

        // Insert enriched click events
        let base_ts = interval_start + 1_000_000;
        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, app_name, window_title, ax_role, ax_title, segment_file)
             VALUES (?1, 2, 'mouse_down', 'Google Chrome', 'Gmail - Google Chrome', 'AXButton', 'Compose', '')",
            params![base_ts as i64],
        ).unwrap();

        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, app_name, window_title, ax_role, ax_title, segment_file)
             VALUES (?1, 2, 'mouse_down', 'Google Chrome', 'Gmail - Google Chrome', 'AXComboBox', 'To recipients', '')",
            params![(base_ts + 2_000_000) as i64],
        ).unwrap();

        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, app_name, window_title, segment_file)
             VALUES (?1, 2, 'key_down', 'Google Chrome', 'Gmail - Google Chrome', '')",
            params![(base_ts + 3_000_000) as i64],
        ).unwrap();

        let results = search_behavioral_context(&conn, "Gmail compose", "Chrome", 5).unwrap();
        assert!(!results.is_empty());
        assert_eq!(results[0].app_name, "Google Chrome");
        assert!(results[0].actions.len() >= 2);
        // First action should have AX enrichment
        assert_eq!(results[0].actions[0].ax_role.as_deref(), Some("AXButton"));
        assert_eq!(results[0].actions[0].ax_title.as_deref(), Some("Compose"));
    }

    #[test]
    fn test_count_enriched_clicks() {
        let conn = setup_test_db();
        let now = wall_micros();

        // Insert one enriched and one non-enriched click
        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, ax_role, ax_title, segment_file)
             VALUES (?1, 2, 'mouse_down', 'AXButton', 'Send', '')",
            params![now as i64],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, segment_file)
             VALUES (?1, 2, 'mouse_down', '')",
            params![(now + 1000) as i64],
        )
        .unwrap();

        let count =
            count_enriched_clicks(&conn, now - 1_000_000, now + 1_000_000).unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_top_interactions() {
        let conn = setup_test_db();
        let now = wall_micros();

        // Insert multiple clicks on the same element
        for i in 0..5 {
            conn.execute(
                "INSERT INTO events_index (ts, track, event_type, app_name, ax_role, ax_title, segment_file)
                 VALUES (?1, 2, 'mouse_down', 'Google Chrome', 'AXButton', 'Compose', '')",
                params![(now + i * 1000) as i64],
            ).unwrap();
        }
        for i in 0..3 {
            conn.execute(
                "INSERT INTO events_index (ts, track, event_type, app_name, ax_role, ax_title, segment_file)
                 VALUES (?1, 2, 'mouse_down', 'Google Chrome', 'AXButton', 'Send', '')",
                params![(now + 10000 + i * 1000) as i64],
            ).unwrap();
        }

        let top = top_interactions(&conn, "Chrome", 10).unwrap();
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].0, "AXButton");
        assert_eq!(top[0].1, "Compose");
        assert_eq!(top[0].2, 5);
        assert_eq!(top[1].1, "Send");
        assert_eq!(top[1].2, 3);
    }

    #[test]
    fn test_sequence_gap_splitting() {
        let conn = setup_test_db();
        let now = wall_micros();
        let interval_start = now - 3_600_000_000;

        conn.execute(
            "INSERT INTO app_focus_intervals (app_name, start_ts, end_ts)
             VALUES ('Safari', ?1, ?2)",
            params![interval_start as i64, now as i64],
        )
        .unwrap();

        // Sequence 1: two clicks close together
        let base = interval_start + 100_000;
        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, app_name, ax_role, ax_title, segment_file)
             VALUES (?1, 2, 'mouse_down', 'Safari', 'AXButton', 'Back', '')",
            params![base as i64],
        ).unwrap();
        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, app_name, ax_role, ax_title, segment_file)
             VALUES (?1, 2, 'mouse_down', 'Safari', 'AXLink', 'Home', '')",
            params![(base + 1_000_000) as i64],
        ).unwrap();

        // Gap of 10 seconds -> new sequence
        let base2 = base + 11_000_000;
        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, app_name, ax_role, ax_title, segment_file)
             VALUES (?1, 2, 'mouse_down', 'Safari', 'AXButton', 'Search', '')",
            params![base2 as i64],
        ).unwrap();
        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, app_name, segment_file)
             VALUES (?1, 2, 'key_down', 'Safari', '')",
            params![(base2 + 500_000) as i64],
        ).unwrap();

        let results = search_behavioral_context(&conn, "Safari", "Safari", 10).unwrap();
        assert_eq!(results.len(), 2, "Should split into two sequences");
    }
}
