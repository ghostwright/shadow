use std::fs;
use std::io;
use std::path::PathBuf;

/// All data directory paths derived from a single root.
#[derive(Debug, Clone)]
pub struct DataPaths {
    pub root: PathBuf,
    pub events: PathBuf,
    pub media_video: PathBuf,
    pub media_audio: PathBuf,
    pub media_keyframes: PathBuf,
    pub indices: PathBuf,
    pub timeline_db: PathBuf,
    pub search_index: PathBuf,
    pub vector_index: PathBuf,
    pub context: PathBuf,
}

impl DataPaths {
    pub fn new(root: &str) -> Self {
        let root = PathBuf::from(root);
        Self {
            events: root.join("events"),
            media_video: root.join("media").join("video"),
            media_audio: root.join("media").join("audio"),
            media_keyframes: root.join("media").join("keyframes"),
            indices: root.join("indices"),
            timeline_db: root.join("indices").join("timeline.db"),
            search_index: root.join("indices").join("search"),
            vector_index: root.join("indices").join("vector"),
            context: root.join("context"),
            root,
        }
    }

    /// Create all required directories if they don't exist.
    pub fn ensure_dirs(&self) -> io::Result<()> {
        fs::create_dir_all(&self.events)?;
        fs::create_dir_all(&self.media_video)?;
        fs::create_dir_all(&self.media_audio)?;
        fs::create_dir_all(&self.media_keyframes)?;
        fs::create_dir_all(&self.indices)?;
        fs::create_dir_all(&self.context)?;
        Ok(())
    }

    /// Path for an event log segment: events/YYYY-MM-DD/HH.msgpack
    pub fn event_segment_path(&self, date: &str, hour: u32) -> PathBuf {
        self.events.join(date).join(format!("{:02}.msgpack", hour))
    }

    /// Path for a compressed event log segment: events/YYYY-MM-DD/HH.msgpack.zst
    pub fn event_segment_compressed_path(&self, date: &str, hour: u32) -> PathBuf {
        self.events
            .join(date)
            .join(format!("{:02}.msgpack.zst", hour))
    }

}
