use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// An AX-anchored step in an extracted workflow. Identifies the target element
/// by its accessibility properties (role, title, identifier) rather than
/// screen coordinates. Coordinates are kept as fallback only.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct AXAnchoredStep {
    pub index: u32,
    /// Human-readable intent (e.g., "Click Compose button").
    pub intent: String,
    /// Action type: "click", "type", "key_press", "scroll", "app_switch".
    pub action_type: String,
    /// AX role of the target element (e.g., "AXButton").
    pub target_role: Option<String>,
    /// AX title/label of the target element (e.g., "Compose").
    pub target_title: Option<String>,
    /// AX identifier for programmatic matching.
    pub target_identifier: Option<String>,
    /// Fallback X coordinate (used only if AX matching fails).
    pub fallback_x: Option<f64>,
    /// Fallback Y coordinate (used only if AX matching fails).
    pub fallback_y: Option<f64>,
    /// Text content for type actions.
    pub text: Option<String>,
    /// Key name for key_press actions (e.g., "Tab", "Return").
    pub key_name: Option<String>,
    /// Modifier keys for hotkey actions (e.g., ["cmd", "shift"]).
    pub modifiers: Vec<String>,
    /// Expected window title when this step executes (context assertion).
    pub expected_window_title: Option<String>,
    /// Expected app name when this step executes (context assertion).
    pub expected_app: Option<String>,
}

/// A workflow candidate extracted from passive observation data.
/// Represents a recurring sequence of user actions within a single app.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ExtractedWorkflow {
    /// Unique identifier for this workflow.
    pub id: String,
    /// Short descriptive name (e.g., "Gmail Compose Email").
    pub name: String,
    /// The primary app where this workflow occurs.
    pub app_name: String,
    /// App bundle identifier.
    pub bundle_id: String,
    /// The window title pattern (most common title seen during workflow).
    pub window_title_pattern: String,
    /// Ordered steps in the workflow.
    pub steps: Vec<AXAnchoredStep>,
    /// How many times this workflow pattern was observed.
    pub occurrence_count: u32,
    /// Confidence score (0.0-1.0) based on consistency across observations.
    pub confidence: f64,
    /// Most recent observation timestamp (microseconds).
    pub last_seen_ts: u64,
    /// First observation timestamp (microseconds).
    pub first_seen_ts: u64,
}

/// Internal representation of a raw action sequence from the events index.
#[derive(Debug, Clone)]
struct RawAction {
    ts: u64,
    event_type: String,
    ax_role: Option<String>,
    ax_title: Option<String>,
    ax_identifier: Option<String>,
    window_title: Option<String>,
    app_name: Option<String>,
    bundle_id: Option<String>,
}

/// A fingerprint for a workflow step, used for pattern matching.
#[derive(Debug, Clone, Hash, PartialEq, Eq)]
struct StepFingerprint {
    action_type: String,
    ax_role: Option<String>,
    ax_title: Option<String>,
}

/// Maximum gap between actions before starting a new segment (5 seconds).
const SEGMENT_GAP_US: u64 = 5_000_000;

/// Minimum number of steps in a workflow to be considered a candidate.
const MIN_WORKFLOW_STEPS: usize = 3;

/// Maximum number of steps in a single workflow.
const MAX_WORKFLOW_STEPS: usize = 30;

/// Minimum number of occurrences before a pattern is considered "recurring".
const MIN_OCCURRENCES: u32 = 2;

/// Extract recurring workflow patterns from the enriched events index.
///
/// Strategy:
/// 1. Fetch recent enriched events grouped by app focus intervals
/// 2. Segment into action sequences (gap > 5s = new segment)
/// 3. Compute fingerprints for each segment
/// 4. Find recurring fingerprint patterns (2+ occurrences)
/// 5. Build AX-anchored steps from the best example of each pattern
///
/// Returns up to `max_results` extracted workflows, most confident first.
pub fn extract_workflows(
    conn: &Connection,
    lookback_hours: u32,
    max_results: u32,
) -> Result<Vec<ExtractedWorkflow>, String> {
    let now_us = wall_micros();
    let lookback_us = (lookback_hours as u64) * 3_600_000_000;
    let start_ts = now_us.saturating_sub(lookback_us);

    // Step 1: Fetch all enriched input events in the lookback window
    let mut stmt = conn
        .prepare(
            "SELECT ts, event_type, ax_role, ax_title, ax_identifier,
                    window_title, app_name, bundle_id
             FROM events_index
             WHERE track = 2
               AND ts >= ?1
               AND event_type IN ('mouse_down', 'key_down', 'scroll')
             ORDER BY ts ASC",
        )
        .map_err(|e| format!("Failed to prepare workflow query: {e}"))?;

    let raw_actions: Vec<RawAction> = stmt
        .query_map(params![start_ts as i64], |row| {
            let ts: i64 = row.get(0)?;
            Ok(RawAction {
                ts: ts as u64,
                event_type: row.get(1)?,
                ax_role: row.get(2)?,
                ax_title: row.get(3)?,
                ax_identifier: row.get(4)?,
                window_title: row.get(5)?,
                app_name: row.get(6)?,
                bundle_id: row.get(7)?,
            })
        })
        .map_err(|e| format!("Workflow query failed: {e}"))?
        .filter_map(|r| r.ok())
        .collect();

    if raw_actions.is_empty() {
        return Ok(vec![]);
    }

    // Step 2: Segment into per-app action sequences
    let segments = segment_actions(&raw_actions);

    // Step 3 & 4: Find recurring patterns by fingerprint
    let patterns = find_recurring_patterns(&segments);

    // Step 5: Build AX-anchored workflows from recurring patterns
    let mut workflows: Vec<ExtractedWorkflow> = patterns
        .into_iter()
        .filter(|p| p.occurrences >= MIN_OCCURRENCES)
        .map(|p| build_workflow(p))
        .collect();

    // Sort by confidence (occurrence count * consistency)
    workflows.sort_by(|a, b| {
        b.confidence
            .partial_cmp(&a.confidence)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    workflows.truncate(max_results as usize);
    Ok(workflows)
}

/// Extract workflows for a specific app.
pub fn extract_workflows_for_app(
    conn: &Connection,
    app_name: &str,
    lookback_hours: u32,
    max_results: u32,
) -> Result<Vec<ExtractedWorkflow>, String> {
    let now_us = wall_micros();
    let lookback_us = (lookback_hours as u64) * 3_600_000_000;
    let start_ts = now_us.saturating_sub(lookback_us);

    let mut stmt = conn
        .prepare(
            "SELECT ts, event_type, ax_role, ax_title, ax_identifier,
                    window_title, app_name, bundle_id
             FROM events_index
             WHERE track = 2
               AND ts >= ?1
               AND app_name LIKE ?2
               AND event_type IN ('mouse_down', 'key_down', 'scroll')
             ORDER BY ts ASC",
        )
        .map_err(|e| format!("Failed to prepare app workflow query: {e}"))?;

    let raw_actions: Vec<RawAction> = stmt
        .query_map(params![start_ts as i64, format!("%{}%", app_name)], |row| {
            let ts: i64 = row.get(0)?;
            Ok(RawAction {
                ts: ts as u64,
                event_type: row.get(1)?,
                ax_role: row.get(2)?,
                ax_title: row.get(3)?,
                ax_identifier: row.get(4)?,
                window_title: row.get(5)?,
                app_name: row.get(6)?,
                bundle_id: row.get(7)?,
            })
        })
        .map_err(|e| format!("App workflow query failed: {e}"))?
        .filter_map(|r| r.ok())
        .collect();

    if raw_actions.is_empty() {
        return Ok(vec![]);
    }

    let segments = segment_actions(&raw_actions);
    let patterns = find_recurring_patterns(&segments);

    let mut workflows: Vec<ExtractedWorkflow> = patterns
        .into_iter()
        .filter(|p| p.occurrences >= MIN_OCCURRENCES)
        .map(|p| build_workflow(p))
        .collect();

    workflows.sort_by(|a, b| {
        b.confidence
            .partial_cmp(&a.confidence)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    workflows.truncate(max_results as usize);
    Ok(workflows)
}

/// A segment of actions within the same app, separated by time gaps.
#[derive(Debug, Clone)]
struct ActionSegment {
    app_name: String,
    bundle_id: String,
    window_title: String,
    actions: Vec<RawAction>,
    start_ts: u64,
    end_ts: u64,
}

/// Segment raw actions into per-app sequences separated by time gaps.
fn segment_actions(actions: &[RawAction]) -> Vec<ActionSegment> {
    let mut segments: Vec<ActionSegment> = Vec::new();
    let mut current_actions: Vec<RawAction> = Vec::new();
    let mut current_app = String::new();
    let mut current_bundle = String::new();
    let mut current_title = String::new();
    let mut seg_start = 0u64;

    for action in actions {
        let app = action.app_name.as_deref().unwrap_or("");
        let should_split = if current_actions.is_empty() {
            false
        } else {
            // Split on: time gap, app change, or max segment size
            let time_gap = action.ts.saturating_sub(current_actions.last().unwrap().ts)
                > SEGMENT_GAP_US;
            let app_change = app != current_app;
            let too_long = current_actions.len() >= MAX_WORKFLOW_STEPS;
            time_gap || app_change || too_long
        };

        if should_split && current_actions.len() >= MIN_WORKFLOW_STEPS {
            segments.push(ActionSegment {
                app_name: current_app.clone(),
                bundle_id: current_bundle.clone(),
                window_title: current_title.clone(),
                start_ts: seg_start,
                end_ts: current_actions.last().unwrap().ts,
                actions: current_actions.clone(),
            });
        }

        if should_split || current_actions.is_empty() {
            current_actions.clear();
            current_app = app.to_string();
            current_bundle = action.bundle_id.as_deref().unwrap_or("").to_string();
            current_title = action.window_title.as_deref().unwrap_or("").to_string();
            seg_start = action.ts;
        }

        current_actions.push(action.clone());
    }

    // Flush remaining
    if current_actions.len() >= MIN_WORKFLOW_STEPS {
        segments.push(ActionSegment {
            app_name: current_app,
            bundle_id: current_bundle,
            window_title: current_title,
            start_ts: seg_start,
            end_ts: current_actions.last().unwrap().ts,
            actions: current_actions,
        });
    }

    segments
}

/// A pattern found in the data: a fingerprint sequence that occurs multiple times.
struct RecurringPattern {
    /// The fingerprint sequence that defines this pattern.
    fingerprint: Vec<StepFingerprint>,
    /// All segments that match this pattern.
    exemplars: Vec<ActionSegment>,
    /// Number of times observed.
    occurrences: u32,
    /// The app name.
    app_name: String,
    bundle_id: String,
}

/// Find recurring fingerprint patterns across segments.
///
/// Generates a fingerprint for each segment (sequence of action_type + ax_role + ax_title),
/// then groups segments by similar fingerprints. Only enriched actions (those with ax_role)
/// contribute to fingerprint matching; unenriched actions are treated as wildcards.
fn find_recurring_patterns(segments: &[ActionSegment]) -> Vec<RecurringPattern> {
    // Group segments by app_name for pattern matching
    let mut by_app: HashMap<String, Vec<&ActionSegment>> = HashMap::new();
    for seg in segments {
        by_app
            .entry(seg.app_name.clone())
            .or_default()
            .push(seg);
    }

    let mut patterns: Vec<RecurringPattern> = Vec::new();

    for (app_name, app_segments) in &by_app {
        if app_segments.len() < MIN_OCCURRENCES as usize {
            continue;
        }

        // Generate fingerprints for each segment (enriched actions only)
        let fingerprinted: Vec<(Vec<StepFingerprint>, &ActionSegment)> = app_segments
            .iter()
            .map(|seg| {
                let fp: Vec<StepFingerprint> = seg
                    .actions
                    .iter()
                    .filter(|a| a.ax_role.is_some()) // Only enriched actions form fingerprint
                    .map(|a| StepFingerprint {
                        action_type: a.event_type.clone(),
                        ax_role: a.ax_role.clone(),
                        ax_title: a.ax_title.clone(),
                    })
                    .collect();
                (fp, *seg)
            })
            .filter(|(fp, _)| fp.len() >= MIN_WORKFLOW_STEPS) // Must have enough enriched actions
            .collect();

        // Group by fingerprint similarity
        // Use exact fingerprint matching first, then fall back to subsequence matching.
        let mut fp_groups: HashMap<String, Vec<(&Vec<StepFingerprint>, &ActionSegment)>> =
            HashMap::new();

        for (fp, seg) in &fingerprinted {
            let key = fingerprint_key(fp);
            fp_groups.entry(key).or_default().push((fp, seg));
        }

        for (_, group) in fp_groups {
            if group.len() < MIN_OCCURRENCES as usize {
                continue;
            }

            let (fp, _) = group[0];
            let exemplars: Vec<ActionSegment> =
                group.iter().map(|(_, seg)| (*seg).clone()).collect();

            patterns.push(RecurringPattern {
                fingerprint: fp.clone(),
                occurrences: exemplars.len() as u32,
                app_name: app_name.clone(),
                bundle_id: exemplars
                    .first()
                    .map(|s| s.bundle_id.clone())
                    .unwrap_or_default(),
                exemplars,
            });
        }
    }

    patterns
}

/// Generate a stable string key from a fingerprint sequence.
fn fingerprint_key(fingerprint: &[StepFingerprint]) -> String {
    fingerprint
        .iter()
        .map(|fp| {
            format!(
                "{}:{}:{}",
                fp.action_type,
                fp.ax_role.as_deref().unwrap_or(""),
                fp.ax_title.as_deref().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("|")
}

/// Build an ExtractedWorkflow from a recurring pattern.
///
/// Uses the most recent exemplar as the template but enriches it
/// with information from all exemplars (e.g., most common window title).
fn build_workflow(pattern: RecurringPattern) -> ExtractedWorkflow {
    // Use the most recent exemplar as the primary source
    let best_exemplar = pattern
        .exemplars
        .iter()
        .max_by_key(|e| e.end_ts)
        .unwrap();

    // Find most common window title across exemplars
    let mut title_counts: HashMap<&str, usize> = HashMap::new();
    for exemplar in &pattern.exemplars {
        *title_counts.entry(&exemplar.window_title).or_default() += 1;
    }
    let common_title = title_counts
        .into_iter()
        .max_by_key(|(_, count)| *count)
        .map(|(title, _)| title.to_string())
        .unwrap_or_default();

    // Build AX-anchored steps from the best exemplar
    let steps: Vec<AXAnchoredStep> = best_exemplar
        .actions
        .iter()
        .enumerate()
        .map(|(i, action)| {
            let intent = build_step_intent(action);
            AXAnchoredStep {
                index: i as u32,
                intent,
                action_type: action.event_type.clone(),
                target_role: action.ax_role.clone(),
                target_title: action.ax_title.clone(),
                target_identifier: action.ax_identifier.clone(),
                fallback_x: None, // Coordinates are not in the index; populated at execution time
                fallback_y: None,
                text: if action.event_type == "key_down" {
                    // Key text would come from the raw event; we don't have it in the index
                    None
                } else {
                    None
                },
                key_name: None,
                modifiers: vec![],
                expected_window_title: action.window_title.clone(),
                expected_app: action.app_name.clone(),
            }
        })
        .collect();

    // Calculate confidence based on occurrence count and enrichment ratio
    let enriched_ratio = best_exemplar
        .actions
        .iter()
        .filter(|a| a.ax_role.is_some())
        .count() as f64
        / best_exemplar.actions.len().max(1) as f64;

    let occurrence_factor = (pattern.occurrences as f64).min(10.0) / 10.0;
    let confidence = (enriched_ratio * 0.6 + occurrence_factor * 0.4).min(1.0);

    let first_seen = pattern
        .exemplars
        .iter()
        .map(|e| e.start_ts)
        .min()
        .unwrap_or(0);
    let last_seen = pattern
        .exemplars
        .iter()
        .map(|e| e.end_ts)
        .max()
        .unwrap_or(0);

    // Generate a name from the app and the most distinctive step
    let distinctive_step = steps
        .iter()
        .find(|s| s.target_title.is_some())
        .or(steps.first());
    let name = if let Some(step) = distinctive_step {
        let action_desc = step
            .target_title
            .as_deref()
            .unwrap_or(&step.action_type);
        format!("{} — {}", pattern.app_name, action_desc)
    } else {
        format!("{} workflow", pattern.app_name)
    };

    ExtractedWorkflow {
        id: format!(
            "wf-{:x}",
            hash_fingerprint(&pattern.fingerprint, &pattern.app_name)
        ),
        name,
        app_name: pattern.app_name,
        bundle_id: pattern.bundle_id,
        window_title_pattern: common_title,
        steps,
        occurrence_count: pattern.occurrences,
        confidence,
        last_seen_ts: last_seen,
        first_seen_ts: first_seen,
    }
}

/// Build a human-readable intent description for a step.
fn build_step_intent(action: &RawAction) -> String {
    let verb = match action.event_type.as_str() {
        "mouse_down" => "Click",
        "key_down" => "Press key",
        "scroll" => "Scroll",
        _ => "Act on",
    };

    if let (Some(role), Some(title)) = (&action.ax_role, &action.ax_title) {
        format!("{} {} \"{}\"", verb, role, title)
    } else if let Some(role) = &action.ax_role {
        format!("{} {}", verb, role)
    } else {
        format!("{} (unenriched)", verb)
    }
}

/// Generate a stable hash from a fingerprint + app name.
fn hash_fingerprint(fingerprint: &[StepFingerprint], app_name: &str) -> u64 {
    // FNV-1a hash
    let mut hash: u64 = 0xcbf29ce484222325;
    let prime: u64 = 0x00000100000001b3;

    for byte in app_name.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(prime);
    }

    for fp in fingerprint {
        for byte in fp.action_type.as_bytes() {
            hash ^= *byte as u64;
            hash = hash.wrapping_mul(prime);
        }
        if let Some(role) = &fp.ax_role {
            for byte in role.as_bytes() {
                hash ^= *byte as u64;
                hash = hash.wrapping_mul(prime);
            }
        }
        if let Some(title) = &fp.ax_title {
            for byte in title.as_bytes() {
                hash ^= *byte as u64;
                hash = hash.wrapping_mul(prime);
            }
        }
    }

    hash
}

/// Get current wall time in microseconds.
fn wall_micros() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
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

    fn insert_enriched_click(
        conn: &Connection,
        ts: u64,
        app: &str,
        bundle: &str,
        title: &str,
        ax_role: &str,
        ax_title: &str,
    ) {
        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, app_name, bundle_id,
             window_title, ax_role, ax_title, segment_file)
             VALUES (?1, 2, 'mouse_down', ?2, ?3, ?4, ?5, ?6, '')",
            params![ts as i64, app, bundle, title, ax_role, ax_title],
        )
        .unwrap();
    }

    fn insert_key_event(conn: &Connection, ts: u64, app: &str, title: &str) {
        conn.execute(
            "INSERT INTO events_index (ts, track, event_type, app_name,
             window_title, segment_file)
             VALUES (?1, 2, 'key_down', ?2, ?3, '')",
            params![ts as i64, app, title],
        )
        .unwrap();
    }

    #[test]
    fn test_extract_empty_db() {
        let conn = setup_test_db();
        let results = extract_workflows(&conn, 24, 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_extract_single_occurrence_not_recurring() {
        let conn = setup_test_db();
        let now = wall_micros();

        // One workflow: 3 enriched clicks in Gmail
        let base = now - 1_000_000_000; // ~17 min ago
        insert_enriched_click(
            &conn,
            base,
            "Chrome",
            "com.google.Chrome",
            "Gmail",
            "AXButton",
            "Compose",
        );
        insert_enriched_click(
            &conn,
            base + 2_000_000,
            "Chrome",
            "com.google.Chrome",
            "Gmail",
            "AXComboBox",
            "To",
        );
        insert_enriched_click(
            &conn,
            base + 4_000_000,
            "Chrome",
            "com.google.Chrome",
            "Gmail",
            "AXButton",
            "Send",
        );

        let results = extract_workflows(&conn, 1, 10).unwrap();
        // Single occurrence should NOT produce a workflow (need 2+)
        assert!(results.is_empty());
    }

    #[test]
    fn test_extract_recurring_pattern() {
        let conn = setup_test_db();
        let now = wall_micros();

        // Create two identical workflows: Gmail compose flow, separated by time gap
        for offset in [0u64, 60_000_000] {
            // Two instances 60 seconds apart
            let base = now - 3_600_000_000 + offset; // within last hour
            insert_enriched_click(
                &conn,
                base,
                "Chrome",
                "com.google.Chrome",
                "Gmail",
                "AXButton",
                "Compose",
            );
            insert_enriched_click(
                &conn,
                base + 1_000_000,
                "Chrome",
                "com.google.Chrome",
                "Gmail",
                "AXComboBox",
                "To",
            );
            insert_enriched_click(
                &conn,
                base + 2_000_000,
                "Chrome",
                "com.google.Chrome",
                "Gmail",
                "AXButton",
                "Send",
            );
            // 10-second gap to separate from next workflow instance
            // (the next instance starts 60s later, so there's a natural gap)
        }

        let results = extract_workflows(&conn, 2, 10).unwrap();
        assert!(!results.is_empty(), "Should find at least one workflow");

        let wf = &results[0];
        assert_eq!(wf.occurrence_count, 2);
        assert_eq!(wf.app_name, "Chrome");
        assert!(wf.confidence > 0.0);
        assert!(wf.steps.len() >= 3);

        // Steps should be AX-anchored
        let first_step = &wf.steps[0];
        assert_eq!(first_step.target_role.as_deref(), Some("AXButton"));
        assert_eq!(first_step.target_title.as_deref(), Some("Compose"));
    }

    #[test]
    fn test_extract_for_app() {
        let conn = setup_test_db();
        let now = wall_micros();

        // Two Gmail workflows
        for offset in [0u64, 60_000_000] {
            let base = now - 3_600_000_000 + offset;
            insert_enriched_click(
                &conn,
                base,
                "Chrome",
                "com.google.Chrome",
                "Gmail",
                "AXButton",
                "Compose",
            );
            insert_enriched_click(
                &conn,
                base + 1_000_000,
                "Chrome",
                "com.google.Chrome",
                "Gmail",
                "AXComboBox",
                "To",
            );
            insert_enriched_click(
                &conn,
                base + 2_000_000,
                "Chrome",
                "com.google.Chrome",
                "Gmail",
                "AXButton",
                "Send",
            );
        }

        // One Slack workflow (not recurring)
        let base2 = now - 1_800_000_000;
        insert_enriched_click(
            &conn,
            base2,
            "Slack",
            "com.tinyspeck.slackmacgap",
            "Slack",
            "AXButton",
            "New Message",
        );
        insert_enriched_click(
            &conn,
            base2 + 1_000_000,
            "Slack",
            "com.tinyspeck.slackmacgap",
            "Slack",
            "AXTextField",
            "To",
        );
        insert_enriched_click(
            &conn,
            base2 + 2_000_000,
            "Slack",
            "com.tinyspeck.slackmacgap",
            "Slack",
            "AXButton",
            "Send",
        );

        // Extract only Chrome workflows
        let results = extract_workflows_for_app(&conn, "Chrome", 2, 10).unwrap();
        assert!(!results.is_empty());
        assert!(results.iter().all(|w| w.app_name == "Chrome"));
    }

    #[test]
    fn test_fingerprint_key_stability() {
        let fp1 = vec![
            StepFingerprint {
                action_type: "mouse_down".into(),
                ax_role: Some("AXButton".into()),
                ax_title: Some("Compose".into()),
            },
            StepFingerprint {
                action_type: "mouse_down".into(),
                ax_role: Some("AXButton".into()),
                ax_title: Some("Send".into()),
            },
        ];

        let fp2 = fp1.clone();
        assert_eq!(fingerprint_key(&fp1), fingerprint_key(&fp2));

        // Different fingerprint should produce different key
        let fp3 = vec![StepFingerprint {
            action_type: "mouse_down".into(),
            ax_role: Some("AXButton".into()),
            ax_title: Some("Cancel".into()),
        }];
        assert_ne!(fingerprint_key(&fp1), fingerprint_key(&fp3));
    }

    #[test]
    fn test_unenriched_actions_excluded_from_fingerprint() {
        let conn = setup_test_db();
        let now = wall_micros();

        // Two workflows with enriched clicks + unenriched key events
        // The unenriched events should not affect fingerprint matching
        for offset in [0u64, 60_000_000] {
            let base = now - 3_600_000_000 + offset;
            insert_enriched_click(
                &conn,
                base,
                "Chrome",
                "com.google.Chrome",
                "Gmail",
                "AXButton",
                "Compose",
            );
            insert_key_event(&conn, base + 500_000, "Chrome", "Gmail");
            insert_enriched_click(
                &conn,
                base + 1_000_000,
                "Chrome",
                "com.google.Chrome",
                "Gmail",
                "AXComboBox",
                "To",
            );
            insert_key_event(&conn, base + 1_500_000, "Chrome", "Gmail");
            insert_enriched_click(
                &conn,
                base + 2_000_000,
                "Chrome",
                "com.google.Chrome",
                "Gmail",
                "AXButton",
                "Send",
            );
        }

        let results = extract_workflows(&conn, 2, 10).unwrap();
        // Should still match because fingerprints only use enriched actions
        assert!(!results.is_empty());
        assert!(results[0].occurrence_count >= 2);
    }

    #[test]
    fn test_gap_splits_segments() {
        let conn = setup_test_db();
        let now = wall_micros();

        // One continuous workflow (should form one segment)
        let base = now - 3_600_000_000;
        insert_enriched_click(
            &conn,
            base,
            "Chrome",
            "com.google.Chrome",
            "Gmail",
            "AXButton",
            "A",
        );
        insert_enriched_click(
            &conn,
            base + 1_000_000,
            "Chrome",
            "com.google.Chrome",
            "Gmail",
            "AXButton",
            "B",
        );
        // 10-second gap -> new segment
        insert_enriched_click(
            &conn,
            base + 11_000_000,
            "Chrome",
            "com.google.Chrome",
            "Gmail",
            "AXButton",
            "C",
        );
        insert_enriched_click(
            &conn,
            base + 12_000_000,
            "Chrome",
            "com.google.Chrome",
            "Gmail",
            "AXButton",
            "D",
        );
        insert_enriched_click(
            &conn,
            base + 13_000_000,
            "Chrome",
            "com.google.Chrome",
            "Gmail",
            "AXButton",
            "E",
        );

        // The first segment has 2 actions (below MIN_WORKFLOW_STEPS=3), so it's skipped.
        // The second segment has 3 actions, so it's included.
        // Neither segment has a duplicate, so no recurring pattern.
        let results = extract_workflows(&conn, 2, 10).unwrap();
        // No recurring pattern from a single segment
        assert!(results.is_empty());
    }

    #[test]
    fn test_build_step_intent() {
        let action = RawAction {
            ts: 0,
            event_type: "mouse_down".to_string(),
            ax_role: Some("AXButton".to_string()),
            ax_title: Some("Send".to_string()),
            ax_identifier: None,
            window_title: None,
            app_name: None,
            bundle_id: None,
        };
        assert_eq!(build_step_intent(&action), "Click AXButton \"Send\"");

        let key_action = RawAction {
            ts: 0,
            event_type: "key_down".to_string(),
            ax_role: None,
            ax_title: None,
            ax_identifier: None,
            window_title: None,
            app_name: None,
            bundle_id: None,
        };
        assert_eq!(build_step_intent(&key_action), "Press key (unenriched)");
    }
}
