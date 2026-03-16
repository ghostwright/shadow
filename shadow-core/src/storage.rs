use std::fs::{self, File};
use std::io::{self, BufWriter, Write};
use std::path::Path;

use chrono::{Local, Timelike};

use crate::config::DataPaths;

/// Metadata about a completed segment rotation.
pub struct RotationInfo {
    /// Path to the old segment file (may have been deleted after compression).
    pub old_raw_path: String,
    /// Path to the compressed file, if compression occurred.
    pub compressed_path: Option<String>,
}

/// Append-only log writer. Writes length-prefixed MessagePack events
/// to hourly segment files.
pub struct LogWriter {
    paths: DataPaths,
    writer: BufWriter<File>,
    current_date: String,
    current_hour: u32,
    events_written: u64,
    /// Set after rotate() — consumed by caller via take_last_rotation().
    last_rotation: Option<RotationInfo>,
}

impl LogWriter {
    pub fn new(paths: &DataPaths) -> io::Result<Self> {
        let now = Local::now();
        let date = now.format("%Y-%m-%d").to_string();
        let hour = now.hour();

        let segment_path = paths.event_segment_path(&date, hour);
        let parent = segment_path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "event segment path has no parent directory")
        })?;
        fs::create_dir_all(parent)?;

        let file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&segment_path)?;

        Ok(Self {
            paths: paths.clone(),
            writer: BufWriter::new(file),
            current_date: date,
            current_hour: hour,
            events_written: 0,
            last_rotation: None,
        })
    }

    /// Append a raw MessagePack event to the current segment.
    /// Format: [u32 little-endian length][msgpack bytes]
    pub fn append(&mut self, data: &[u8]) -> io::Result<()> {
        // Check if we need to rotate (new hour)
        let now = Local::now();
        let date = now.format("%Y-%m-%d").to_string();
        let hour = now.hour();

        if hour != self.current_hour || date != self.current_date {
            self.rotate()?;
        }

        // Write length prefix + data
        let len = u32::try_from(data.len()).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidData, "event exceeds 4GB size limit")
        })?;
        self.writer.write_all(&len.to_le_bytes())?;
        self.writer.write_all(data)?;
        self.events_written += 1;

        // Flush after every write. Our events are infrequent (window changes,
        // app switches — maybe once every few seconds) and small (< 500 bytes).
        // The BufWriter still batches the underlying write syscalls, but we
        // ensure data hits disk promptly so nothing is lost on crash/kill.
        self.writer.flush()?;

        Ok(())
    }

    /// Get the path of the current segment file.
    pub fn current_segment_path(&self) -> String {
        self.paths
            .event_segment_path(&self.current_date, self.current_hour)
            .to_string_lossy()
            .to_string()
    }

    /// Flush the current writer, compress the old segment, and open a new one.
    pub fn rotate(&mut self) -> io::Result<()> {
        // Flush current writer
        self.writer.flush()?;

        let old_date = self.current_date.clone();
        let old_hour = self.current_hour;
        let old_path = self.paths.event_segment_path(&old_date, old_hour);
        let old_path_str = old_path.to_string_lossy().to_string();

        // Compress the completed segment in a background-friendly way
        if old_path.exists() && fs::metadata(&old_path)?.len() > 0 {
            let compressed_path = self.paths.event_segment_compressed_path(&old_date, old_hour);
            compress_segment(&old_path, &compressed_path)?;
            fs::remove_file(&old_path)?;
            self.last_rotation = Some(RotationInfo {
                old_raw_path: old_path_str,
                compressed_path: Some(compressed_path.to_string_lossy().to_string()),
            });
        } else {
            self.last_rotation = Some(RotationInfo {
                old_raw_path: old_path_str,
                compressed_path: None,
            });
        }

        // Update to current time
        let now = Local::now();
        self.current_date = now.format("%Y-%m-%d").to_string();
        self.current_hour = now.hour();

        // Open new segment
        let new_path = self
            .paths
            .event_segment_path(&self.current_date, self.current_hour);
        let parent = new_path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "event segment path has no parent directory")
        })?;
        fs::create_dir_all(parent)?;

        let file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&new_path)?;

        self.writer = BufWriter::new(file);
        self.events_written = 0;

        Ok(())
    }

    /// Consume the last rotation info, if any. Called after append/rotate
    /// to learn what happened for segment table updates.
    pub fn take_last_rotation(&mut self) -> Option<RotationInfo> {
        self.last_rotation.take()
    }

    /// Flush without rotating. Call on app quit.
    #[allow(dead_code)]
    pub fn flush(&mut self) -> io::Result<()> {
        self.writer.flush()
    }
}

/// Compress a segment file with zstd (level 3 — fast, good ratio).
fn compress_segment(src: &Path, dst: &Path) -> io::Result<()> {
    let input = fs::read(src)?;
    let compressed = zstd::encode_all(input.as_slice(), 3)?;
    fs::write(dst, compressed)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use tempfile::TempDir;

    fn make_test_paths() -> (TempDir, DataPaths) {
        let tmp = TempDir::new().unwrap();
        let paths = DataPaths::new(tmp.path().to_str().unwrap());
        paths.ensure_dirs().unwrap();
        (tmp, paths)
    }

    #[test]
    fn test_write_and_read_back() {
        let (_tmp, paths) = make_test_paths();
        let mut writer = LogWriter::new(&paths).unwrap();

        // Write a test event
        let mut event: HashMap<&str, rmpv::Value> = HashMap::new();
        event.insert("ts", rmpv::Value::from(1708300800000000u64));
        event.insert("track", rmpv::Value::from(3u8));
        event.insert("type", rmpv::Value::from("test"));

        let bytes = rmp_serde::to_vec(&event).unwrap();
        writer.append(&bytes).unwrap();
        writer.flush().unwrap();

        // Verify the segment file exists and has data
        let segment = paths.event_segment_path(
            &Local::now().format("%Y-%m-%d").to_string(),
            Local::now().hour(),
        );
        assert!(segment.exists());
        assert!(fs::metadata(&segment).unwrap().len() > 0);
    }
}
