use serde::{Deserialize, Serialize};

/// Minimal header extracted from a raw MessagePack event.
/// Supports both v1 (ts/track/type only) and v2 (full envelope) events.
/// The full event may have many more fields — we only extract what the index needs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventHeader {
    // Core fields (v1 compat — always present)
    pub ts: u64,
    pub track: u8,
    #[serde(default)]
    pub r#type: Option<String>,
    #[serde(default)]
    pub app_name: Option<String>,
    #[serde(default)]
    pub window_title: Option<String>,
    #[serde(default)]
    pub url: Option<String>,

    // v2 envelope fields (optional, absent for v1 events)
    #[serde(default)]
    pub v: Option<u8>,
    #[serde(default)]
    pub ts_wall_us: Option<u64>,
    #[serde(default)]
    pub ts_mono_ns: Option<u64>,
    #[serde(default)]
    pub seq: Option<u64>,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub display_id: Option<u32>,
    #[serde(default)]
    pub pid: Option<i32>,
    #[serde(default)]
    pub bundle_id: Option<String>,

    // AX enrichment fields (Mimicry Phase A1 — added to mouse_down events)
    #[serde(default)]
    pub ax_role: Option<String>,
    #[serde(default)]
    pub ax_title: Option<String>,
    #[serde(default)]
    pub ax_identifier: Option<String>,

    // Click coordinates (Mimicry — stored for training data generation)
    #[serde(default)]
    pub click_x: Option<i32>,
    #[serde(default)]
    pub click_y: Option<i32>,
}

impl EventHeader {
    /// Effective timestamp: prefers ts_wall_us (v2) over ts (v1).
    pub fn effective_ts(&self) -> u64 {
        self.ts_wall_us.unwrap_or(self.ts)
    }

    /// Whether this is a v2 envelope event.
    pub fn is_v2(&self) -> bool {
        self.v.map_or(false, |v| v >= 2)
    }
}

/// Parse just the header fields from a raw MessagePack event.
pub fn parse_event_header(data: &[u8]) -> Result<EventHeader, rmp_serde::decode::Error> {
    // Deserialize into EventHeader — serde will ignore unknown fields
    rmp_serde::from_slice(data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn test_parse_v1_header() {
        let mut event: HashMap<&str, rmpv::Value> = HashMap::new();
        event.insert("ts", rmpv::Value::from(1708300800000000u64));
        event.insert("track", rmpv::Value::from(3u8));
        event.insert("type", rmpv::Value::from("app_switch"));
        event.insert("app_name", rmpv::Value::from("VS Code"));
        event.insert(
            "window_title",
            rmpv::Value::from("main.rs - shadow - VS Code"),
        );
        event.insert("pid", rmpv::Value::from(1234));

        let bytes = rmp_serde::to_vec(&event).unwrap();
        let header = parse_event_header(&bytes).unwrap();

        assert_eq!(header.ts, 1708300800000000);
        assert_eq!(header.track, 3);
        assert_eq!(header.r#type.as_deref(), Some("app_switch"));
        assert_eq!(header.app_name.as_deref(), Some("VS Code"));
        assert!(!header.is_v2());
        assert_eq!(header.effective_ts(), 1708300800000000);
        // pid is now extracted as a v2 field
        assert_eq!(header.pid, Some(1234));
    }

    #[test]
    fn test_parse_v2_header() {
        let mut event: HashMap<&str, rmpv::Value> = HashMap::new();
        event.insert("v", rmpv::Value::from(2u8));
        event.insert("ts", rmpv::Value::from(1771645325123456u64));
        event.insert("ts_wall_us", rmpv::Value::from(1771645325123456u64));
        event.insert("ts_mono_ns", rmpv::Value::from(88231511223344u64));
        event.insert("seq", rmpv::Value::from(18233u64));
        event.insert(
            "session_id",
            rmpv::Value::from("5d66b4f4-5c76-4a8d-9f68-72db9b2d6c4e"),
        );
        event.insert("track", rmpv::Value::from(2u8));
        event.insert("type", rmpv::Value::from("key_down"));
        event.insert("source", rmpv::Value::from("input_monitor"));
        event.insert("display_id", rmpv::Value::from(69734112u32));
        event.insert("pid", rmpv::Value::from(18492i32));
        event.insert("bundle_id", rmpv::Value::from("com.google.Chrome"));
        event.insert("app_name", rmpv::Value::from("Google Chrome"));
        event.insert("key_code", rmpv::Value::from(13)); // track-specific, not in header

        let bytes = rmp_serde::to_vec(&event).unwrap();
        let header = parse_event_header(&bytes).unwrap();

        assert!(header.is_v2());
        assert_eq!(header.effective_ts(), 1771645325123456);
        assert_eq!(header.seq, Some(18233));
        assert_eq!(
            header.session_id.as_deref(),
            Some("5d66b4f4-5c76-4a8d-9f68-72db9b2d6c4e")
        );
        assert_eq!(header.source.as_deref(), Some("input_monitor"));
        assert_eq!(header.display_id, Some(69734112));
        assert_eq!(header.pid, Some(18492));
        assert_eq!(
            header.bundle_id.as_deref(),
            Some("com.google.Chrome")
        );
    }
}
