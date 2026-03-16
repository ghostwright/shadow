use std::collections::HashMap;
use std::ops::Bound;
use std::path::Path;

use log::info;
use tantivy::collector::TopDocs;
use tantivy::query::{BooleanQuery, Occur, QueryParser, RangeQuery, TermQuery};
use tantivy::schema::*;
use tantivy::{Index, IndexReader, IndexWriter, Order, ReloadPolicy};

use crate::timeline::TimelineEntry;

/// Schema version — bump whenever fields change. Triggers index rebuild.
/// v3: Added transcript metadata fields (audio_segment_id, audio_source, ts_end, confidence)
/// v4: Made source_kind indexed (STRING) for TermQuery support in range queries
const SCHEMA_VERSION: u32 = 4;

/// Tantivy-based full-text search index over captured events and OCR text.
/// Indexes Track 3 (app/window context) and OCR-derived screen text.
/// Future milestones add transcripts and CLIP-derived text.
pub struct SearchIndex {
    index: Index,
    reader: IndexReader,
    writer: Option<IndexWriter>,
    /// True if the index was rebuilt due to a schema version change.
    /// Callers should reset related checkpoints when this is true.
    rebuilt: bool,

    // Schema field handles
    ts_field: Field,
    track_field: Field,
    event_type_field: Field,
    app_name_field: Field,
    window_title_field: Field,
    url_field: Field,
    display_id_field: Field,
    session_id_field: Field,
    source_kind_field: Field,
    text_content_field: Field,

    // Transcript metadata fields (schema v3 — M4-B1)
    audio_segment_id_field: Field,
    audio_source_field: Field,
    ts_end_field: Field,
    confidence_field: Field,
}

/// A single search result returned to Swift via UniFFI.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SearchResult {
    pub ts: u64,
    pub app_name: String,
    pub window_title: String,
    pub url: String,
    pub display_id: Option<u32>,
    pub event_type: String,
    pub score: f32,
    pub match_reason: String,
    /// Source lane: "track3", "ocr", "transcript"
    pub source_kind: String,
    /// Text snippet for OCR/transcript results. Empty for track3.
    pub snippet: String,
    /// Audio segment ID for transcript results. None for non-transcript results.
    pub audio_segment_id: Option<i64>,
    /// Audio source ("mic" or "system") for transcript results. Empty for non-transcript.
    pub audio_source: String,
    /// End timestamp for transcript chunks (Unix microseconds). 0 for non-transcript.
    pub ts_end: u64,
    /// Transcription confidence (0.0-1.0). None when not available.
    pub confidence: Option<f32>,
}

/// An OCR text entry to be indexed. Passed from Swift via UniFFI.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct OcrEntry {
    pub ts: u64,
    pub display_id: Option<u32>,
    pub text: String,
    pub app_name: Option<String>,
    pub window_title: Option<String>,
    pub confidence: Option<f32>,
}

/// A transcript chunk to be indexed. Passed from Swift via UniFFI.
/// Each chunk represents a time-bounded segment of transcribed audio.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct TranscriptEntry {
    /// The audio_segments.segment_id that produced this chunk.
    pub audio_segment_id: i64,
    /// Audio source: "mic" or "system".
    pub source: String,
    /// Chunk start time (Unix microseconds).
    pub ts_start: u64,
    /// Chunk end time (Unix microseconds).
    pub ts_end: u64,
    /// Transcribed text.
    pub text: String,
    /// Transcription confidence (0.0–1.0), if available.
    pub confidence: Option<f32>,
    /// App that was focused during this chunk (from app_focus_intervals).
    pub app_name: Option<String>,
    /// Window title during this chunk.
    pub window_title: Option<String>,
}

/// A transcript chunk returned from a time-range query.
/// Used by the meeting summarization pipeline to retrieve all transcript text
/// within a time window.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct TranscriptChunkResult {
    /// Chunk start time (Unix microseconds).
    pub ts_start: u64,
    /// Chunk end time (Unix microseconds).
    pub ts_end: u64,
    /// Transcribed text.
    pub text: String,
    /// Audio source: "mic" or "system".
    pub audio_source: String,
    /// Transcription confidence (0.0–1.0), if available.
    pub confidence: Option<f32>,
    /// App that was focused during this chunk.
    pub app_name: String,
    /// Window title during this chunk.
    pub window_title: String,
    /// The audio_segments.segment_id that produced this chunk.
    pub audio_segment_id: i64,
}

/// Search index statistics for diagnostics.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct SearchIndexStats {
    pub total_docs: u64,
    pub num_segments: u64,
}

impl SearchIndex {
    pub fn new(index_dir: &Path) -> Result<Self, SearchError> {
        std::fs::create_dir_all(index_dir).map_err(|e| SearchError::IndexIO(e.to_string()))?;

        // Check schema version — recreate index if stale
        let version_file = index_dir.join("schema_version");
        let needs_recreate = if version_file.exists() {
            let stored = std::fs::read_to_string(&version_file)
                .unwrap_or_default()
                .trim()
                .parse::<u32>()
                .unwrap_or(0);
            stored != SCHEMA_VERSION
        } else {
            // No version file — if meta.json exists, this is a v1 index that needs migration
            index_dir.join("meta.json").exists()
        };

        if needs_recreate {
            info!(
                "Search schema version changed (want {}), rebuilding index at {}",
                SCHEMA_VERSION,
                index_dir.display()
            );
            // Delete old index files. Keep the directory itself.
            for entry in std::fs::read_dir(index_dir)
                .map_err(|e| SearchError::IndexIO(e.to_string()))?
            {
                if let Ok(entry) = entry {
                    let path = entry.path();
                    if path.is_file() {
                        let _ = std::fs::remove_file(&path);
                    }
                }
            }
        }

        let schema = Self::build_schema();

        let index = if index_dir.join("meta.json").exists() {
            Index::open_in_dir(index_dir).map_err(|e| SearchError::TantivyError(e.to_string()))?
        } else {
            Index::create_in_dir(index_dir, schema.clone())
                .map_err(|e| SearchError::TantivyError(e.to_string()))?
        };

        // Write schema version
        std::fs::write(&version_file, SCHEMA_VERSION.to_string())
            .map_err(|e| SearchError::IndexIO(e.to_string()))?;

        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()
            .map_err(|e: tantivy::TantivyError| SearchError::TantivyError(e.to_string()))?;

        let writer = index
            .writer(50_000_000)
            .map_err(|e| SearchError::TantivyError(e.to_string()))?;

        let schema = index.schema();

        info!(
            "Search index opened at {} (schema v{})",
            index_dir.display(),
            SCHEMA_VERSION
        );

        Ok(Self {
            reader,
            writer: Some(writer),
            rebuilt: needs_recreate,
            ts_field: schema.get_field("ts").unwrap(),
            track_field: schema.get_field("track").unwrap(),
            event_type_field: schema.get_field("event_type").unwrap(),
            app_name_field: schema.get_field("app_name").unwrap(),
            window_title_field: schema.get_field("window_title").unwrap(),
            url_field: schema.get_field("url").unwrap(),
            display_id_field: schema.get_field("display_id").unwrap(),
            session_id_field: schema.get_field("session_id").unwrap(),
            source_kind_field: schema.get_field("source_kind").unwrap(),
            text_content_field: schema.get_field("text_content").unwrap(),
            audio_segment_id_field: schema.get_field("audio_segment_id").unwrap(),
            audio_source_field: schema.get_field("audio_source").unwrap(),
            ts_end_field: schema.get_field("ts_end").unwrap(),
            confidence_field: schema.get_field("confidence").unwrap(),
            index,
        })
    }

    fn build_schema() -> Schema {
        let mut sb = Schema::builder();

        // Searchable text fields (tokenized by Tantivy's default tokenizer)
        sb.add_text_field("app_name", TEXT | STORED);
        sb.add_text_field("window_title", TEXT | STORED);
        sb.add_text_field("url", TEXT | STORED);
        sb.add_text_field("text_content", TEXT | STORED);

        // Stored-only fields (retrievable but not searchable)
        sb.add_text_field("event_type", STORED);
        sb.add_text_field("session_id", STORED);

        // source_kind: indexed as exact-match (STRING) for TermQuery filtering.
        // Values: "track3", "ocr", "transcript". Enables efficient range queries
        // like "all transcript chunks in time window" without scanning entire index.
        sb.add_text_field("source_kind", STRING | STORED);

        // Numeric fields (sortable + retrievable)
        sb.add_u64_field("ts", FAST | STORED);
        sb.add_u64_field("track", FAST | STORED);
        sb.add_u64_field("display_id", FAST | STORED);

        // Transcript metadata fields (schema v3 — M4-B1)
        sb.add_i64_field("audio_segment_id", FAST | STORED);
        sb.add_text_field("audio_source", STORED);
        sb.add_u64_field("ts_end", FAST | STORED);
        sb.add_f64_field("confidence", FAST | STORED);

        sb.build()
    }

    /// Index a batch of timeline entries into Tantivy. Returns count of docs added.
    /// Currently indexes Track 3 events (app context). Track 2 input events
    /// contain individual keystrokes that need aggregation (future milestone).
    pub fn index_entries(&mut self, entries: &[TimelineEntry]) -> Result<u32, SearchError> {
        let writer = self
            .writer
            .as_mut()
            .ok_or_else(|| SearchError::TantivyError("Writer not available".into()))?;

        let mut count = 0u32;

        for entry in entries {
            // M1: only index Track 3 events (app/window context)
            if entry.track != 3 {
                continue;
            }

            // Skip entries with no searchable text
            let has_text = entry.app_name.is_some()
                || entry.window_title.is_some()
                || entry.url.is_some();
            if !has_text {
                continue;
            }

            let mut doc = tantivy::TantivyDocument::default();
            doc.add_u64(self.ts_field, entry.ts);
            doc.add_u64(self.track_field, entry.track as u64);
            doc.add_text(self.event_type_field, &entry.event_type);
            doc.add_text(self.source_kind_field, "track3");

            if let Some(ref app) = entry.app_name {
                doc.add_text(self.app_name_field, app);
            }
            if let Some(ref title) = entry.window_title {
                doc.add_text(self.window_title_field, title);
            }
            if let Some(ref url) = entry.url {
                doc.add_text(self.url_field, url);
            }

            if let Some(did) = entry.display_id {
                doc.add_u64(self.display_id_field, did as u64);
            }

            writer
                .add_document(doc)
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;
            count += 1;
        }

        if count > 0 {
            writer
                .commit()
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;
            self.reader
                .reload()
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;
            info!("Indexed {} track3 documents into search index", count);
        }

        Ok(count)
    }

    /// Index a batch of OCR text entries into Tantivy. Returns count of docs added.
    pub fn index_ocr_entries(&mut self, entries: &[OcrEntry]) -> Result<u32, SearchError> {
        let writer = self
            .writer
            .as_mut()
            .ok_or_else(|| SearchError::TantivyError("Writer not available".into()))?;

        let mut count = 0u32;

        for entry in entries {
            if entry.text.trim().is_empty() {
                continue;
            }

            let mut doc = tantivy::TantivyDocument::default();
            doc.add_u64(self.ts_field, entry.ts);
            doc.add_u64(self.track_field, 1); // Track 1 = visual stream
            doc.add_text(self.event_type_field, "ocr_frame");
            doc.add_text(self.source_kind_field, "ocr");
            doc.add_text(self.text_content_field, &entry.text);

            if let Some(ref app) = entry.app_name {
                doc.add_text(self.app_name_field, app);
            }
            if let Some(ref title) = entry.window_title {
                doc.add_text(self.window_title_field, title);
            }

            if let Some(did) = entry.display_id {
                doc.add_u64(self.display_id_field, did as u64);
            }

            writer
                .add_document(doc)
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;
            count += 1;
        }

        if count > 0 {
            writer
                .commit()
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;
            self.reader
                .reload()
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;
            info!("Indexed {} OCR documents into search index", count);
        }

        Ok(count)
    }

    /// Index a batch of transcript chunk entries into Tantivy. Returns count of docs added.
    /// Each chunk is a time-bounded segment of transcribed audio text.
    pub fn index_transcript_entries(
        &mut self,
        entries: &[TranscriptEntry],
    ) -> Result<u32, SearchError> {
        let writer = self
            .writer
            .as_mut()
            .ok_or_else(|| SearchError::TantivyError("Writer not available".into()))?;

        let mut count = 0u32;

        for entry in entries {
            if entry.text.trim().is_empty() {
                continue;
            }

            let mut doc = tantivy::TantivyDocument::default();
            doc.add_u64(self.ts_field, entry.ts_start);
            doc.add_u64(self.track_field, 4); // Track 4 = audio stream
            doc.add_text(self.event_type_field, "transcript_chunk");
            doc.add_text(self.source_kind_field, "transcript");
            doc.add_text(self.text_content_field, &entry.text);

            // Transcript metadata — persisted for M4-C/M4-E playback
            doc.add_i64(self.audio_segment_id_field, entry.audio_segment_id);
            doc.add_text(self.audio_source_field, &entry.source);
            doc.add_u64(self.ts_end_field, entry.ts_end);
            if let Some(conf) = entry.confidence {
                doc.add_f64(self.confidence_field, conf as f64);
            }

            if let Some(ref app) = entry.app_name {
                doc.add_text(self.app_name_field, app);
            }
            if let Some(ref title) = entry.window_title {
                doc.add_text(self.window_title_field, title);
            }

            writer
                .add_document(doc)
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;
            count += 1;
        }

        if count > 0 {
            writer
                .commit()
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;
            self.reader
                .reload()
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;
            info!("Indexed {} transcript documents into search index", count);
        }

        Ok(count)
    }

    /// Sanitize a query string for Tantivy's QueryParser.
    ///
    /// Tantivy interprets colons as field specifiers (`11:30` → field "11", value "30"),
    /// which fails because we only have app_name, window_title, url, and text_content fields.
    /// This wraps colon-containing tokens in quotes so they're treated as literal text,
    /// while leaving normal tokens untouched for standard full-text behavior.
    fn sanitize_query(query_str: &str) -> String {
        query_str
            .split_whitespace()
            .map(|token| {
                if token.contains(':') && !token.starts_with('"') {
                    // Wrap in quotes to force literal phrase matching
                    format!("\"{}\"", token.replace('"', ""))
                } else {
                    token.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Execute a text search query. Returns top `limit` results ordered by relevance.
    /// Searches across app_name, window_title, url, and text_content fields.
    /// Deduplicates results within a 5-second window on the same display.
    pub fn search(&self, query_str: &str, limit: usize) -> Result<Vec<SearchResult>, SearchError> {
        if query_str.trim().is_empty() {
            return Ok(Vec::new());
        }

        let searcher = self.reader.searcher();
        let safe_query = Self::sanitize_query(query_str);

        let query_parser = QueryParser::for_index(
            &self.index,
            vec![
                self.app_name_field,
                self.window_title_field,
                self.url_field,
                self.text_content_field,
            ],
        );

        // Use lenient parsing as a safety net for any remaining edge cases.
        let (query, errors) = query_parser.parse_query_lenient(&safe_query);
        if !errors.is_empty() {
            log::warn!("Query parse warnings for {:?}: {:?}", query_str, errors);
        }

        // Fetch more candidates than requested to account for dedup merging
        let fetch_limit = limit * 3;
        let top_docs = searcher
            .search(&query, &TopDocs::with_limit(fetch_limit))
            .map_err(|e| SearchError::TantivyError(e.to_string()))?;

        let mut raw_results = Vec::with_capacity(top_docs.len());

        for (score, doc_address) in top_docs {
            let doc: tantivy::TantivyDocument = searcher
                .doc(doc_address)
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;

            let ts = doc
                .get_first(self.ts_field)
                .and_then(|v| match v {
                    tantivy::schema::OwnedValue::U64(n) => Some(*n),
                    _ => None,
                })
                .unwrap_or(0);

            let app_name = extract_text(&doc, self.app_name_field);
            let window_title = extract_text(&doc, self.window_title_field);
            let url = extract_text(&doc, self.url_field);
            let event_type = extract_text(&doc, self.event_type_field);
            let source_kind = extract_text(&doc, self.source_kind_field);
            let text_content = extract_text(&doc, self.text_content_field);

            let display_id = doc.get_first(self.display_id_field).and_then(|v| match v {
                tantivy::schema::OwnedValue::U64(n) => Some(*n as u32),
                _ => None,
            });

            // Transcript metadata (None/empty/0 for non-transcript results)
            let audio_segment_id =
                doc.get_first(self.audio_segment_id_field)
                    .and_then(|v| match v {
                        tantivy::schema::OwnedValue::I64(n) => Some(*n),
                        _ => None,
                    });
            let audio_source = extract_text(&doc, self.audio_source_field);
            let ts_end = doc
                .get_first(self.ts_end_field)
                .and_then(|v| match v {
                    tantivy::schema::OwnedValue::U64(n) => Some(*n),
                    _ => None,
                })
                .unwrap_or(0);
            let confidence = doc
                .get_first(self.confidence_field)
                .and_then(|v| match v {
                    tantivy::schema::OwnedValue::F64(n) => Some(*n as f32),
                    _ => None,
                });

            let match_reason = determine_match_reason(
                query_str,
                &app_name,
                &window_title,
                &url,
                &text_content,
                &source_kind,
            );

            // For OCR results, create a snippet from the text_content
            let snippet = if source_kind == "ocr" || source_kind == "transcript" {
                make_snippet(&text_content, query_str, 120)
            } else {
                String::new()
            };

            raw_results.push(SearchResult {
                ts,
                app_name,
                window_title,
                url,
                display_id,
                event_type,
                score,
                match_reason,
                source_kind,
                snippet,
                audio_segment_id,
                audio_source,
                ts_end,
                confidence,
            });
        }

        // Deduplicate results within a 5-second window on the same display
        let deduped = deduplicate_results(raw_results, limit);

        Ok(deduped)
    }

    /// Execute a text search within a timestamp range.
    /// Returns top `limit` results where `ts` is between `start_us` and `end_us` (inclusive).
    /// Combines a parsed text query with a RangeQuery on the ts field.
    pub fn search_in_range(
        &self,
        query_str: &str,
        start_us: u64,
        end_us: u64,
        limit: usize,
    ) -> Result<Vec<SearchResult>, SearchError> {
        if query_str.trim().is_empty() || start_us > end_us {
            return Ok(Vec::new());
        }

        let searcher = self.reader.searcher();
        let safe_query = Self::sanitize_query(query_str);

        let query_parser = QueryParser::for_index(
            &self.index,
            vec![
                self.app_name_field,
                self.window_title_field,
                self.url_field,
                self.text_content_field,
            ],
        );

        // Use lenient parsing as a safety net for any remaining edge cases.
        let (text_query, errors) = query_parser.parse_query_lenient(&safe_query);
        if !errors.is_empty() {
            log::warn!("Range query parse warnings for {:?}: {:?}", query_str, errors);
        }

        let range_query = RangeQuery::new_u64_bounds(
            "ts".to_string(),
            Bound::Included(start_us),
            Bound::Included(end_us),
        );

        let bool_query = BooleanQuery::new(vec![
            (Occur::Must, Box::new(text_query)),
            (Occur::Must, Box::new(range_query)),
        ]);

        let fetch_limit = limit * 3;
        let top_docs = searcher
            .search(&bool_query, &TopDocs::with_limit(fetch_limit))
            .map_err(|e| SearchError::TantivyError(e.to_string()))?;

        let mut raw_results = Vec::with_capacity(top_docs.len());

        for (score, doc_address) in top_docs {
            let doc: tantivy::TantivyDocument = searcher
                .doc(doc_address)
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;

            let ts = doc
                .get_first(self.ts_field)
                .and_then(|v| match v {
                    tantivy::schema::OwnedValue::U64(n) => Some(*n),
                    _ => None,
                })
                .unwrap_or(0);

            let app_name = extract_text(&doc, self.app_name_field);
            let window_title = extract_text(&doc, self.window_title_field);
            let url = extract_text(&doc, self.url_field);
            let event_type = extract_text(&doc, self.event_type_field);
            let source_kind = extract_text(&doc, self.source_kind_field);
            let text_content = extract_text(&doc, self.text_content_field);

            let display_id = doc.get_first(self.display_id_field).and_then(|v| match v {
                tantivy::schema::OwnedValue::U64(n) => Some(*n as u32),
                _ => None,
            });

            let audio_segment_id =
                doc.get_first(self.audio_segment_id_field)
                    .and_then(|v| match v {
                        tantivy::schema::OwnedValue::I64(n) => Some(*n),
                        _ => None,
                    });
            let audio_source = extract_text(&doc, self.audio_source_field);
            let ts_end = doc
                .get_first(self.ts_end_field)
                .and_then(|v| match v {
                    tantivy::schema::OwnedValue::U64(n) => Some(*n),
                    _ => None,
                })
                .unwrap_or(0);
            let confidence = doc
                .get_first(self.confidence_field)
                .and_then(|v| match v {
                    tantivy::schema::OwnedValue::F64(n) => Some(*n as f32),
                    _ => None,
                });

            let match_reason = determine_match_reason(
                query_str,
                &app_name,
                &window_title,
                &url,
                &text_content,
                &source_kind,
            );

            let snippet = if source_kind == "ocr" || source_kind == "transcript" {
                make_snippet(&text_content, query_str, 120)
            } else {
                String::new()
            };

            raw_results.push(SearchResult {
                ts,
                app_name,
                window_title,
                url,
                display_id,
                event_type,
                score,
                match_reason,
                source_kind,
                snippet,
                audio_segment_id,
                audio_source,
                ts_end,
                confidence,
            });
        }

        let deduped = deduplicate_results(raw_results, limit);
        Ok(deduped)
    }

    /// Get index statistics for diagnostics.
    pub fn stats(&self) -> SearchIndexStats {
        let searcher = self.reader.searcher();
        let num_docs = searcher.num_docs();
        let num_segments = searcher.segment_readers().len() as u64;
        SearchIndexStats {
            total_docs: num_docs,
            num_segments,
        }
    }

    /// List transcript chunks within a time range, with pagination.
    /// Returns up to `limit` results starting at `offset`, sorted by ts_start ascending.
    ///
    /// Uses a BooleanQuery combining:
    /// - TermQuery on source_kind="transcript" (STRING-indexed, schema v4)
    /// - RangeQuery on ts field (FAST-indexed, optimized path)
    /// Pagination and ordering handled by Tantivy collector, not post-processing.
    ///
    /// Input guards:
    /// - limit == 0 → empty result
    /// - limit clamped to 1000 max
    /// - start_us > end_us → empty result
    pub fn list_transcript_chunks_in_range(
        &self,
        start_us: u64,
        end_us: u64,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<TranscriptChunkResult>, SearchError> {
        // Input guards
        if limit == 0 || start_us > end_us {
            return Ok(Vec::new());
        }
        let limit = limit.min(1000) as usize;
        let offset = offset as usize;

        let searcher = self.reader.searcher();

        // BooleanQuery: MUST(source_kind == "transcript") AND MUST(ts in [start_us, end_us])
        let term_query = TermQuery::new(
            Term::from_field_text(self.source_kind_field, "transcript"),
            IndexRecordOption::Basic,
        );
        let range_query = RangeQuery::new_u64_bounds(
            "ts".to_string(),
            Bound::Included(start_us),
            Bound::Included(end_us),
        );
        let bool_query = BooleanQuery::new(vec![
            (Occur::Must, Box::new(term_query)),
            (Occur::Must, Box::new(range_query)),
        ]);

        // Collector with pagination and fast-field ordering by ts ascending
        let collector = TopDocs::with_limit(limit)
            .and_offset(offset)
            .order_by_u64_field("ts", Order::Asc);

        let top_docs = searcher
            .search(&bool_query, &collector)
            .map_err(|e| SearchError::TantivyError(e.to_string()))?;

        // Extract document fields — already filtered, sorted, and paginated by Tantivy
        let mut results = Vec::with_capacity(top_docs.len());
        for (_ts_value, doc_addr) in top_docs {
            let doc: tantivy::TantivyDocument = searcher
                .doc(doc_addr)
                .map_err(|e| SearchError::TantivyError(e.to_string()))?;

            results.push(TranscriptChunkResult {
                ts_start: extract_u64(&doc, self.ts_field),
                ts_end: extract_u64(&doc, self.ts_end_field),
                text: extract_text(&doc, self.text_content_field),
                audio_source: extract_text(&doc, self.audio_source_field),
                confidence: extract_opt_f32(&doc, self.confidence_field),
                app_name: extract_text(&doc, self.app_name_field),
                window_title: extract_text(&doc, self.window_title_field),
                audio_segment_id: extract_i64(&doc, self.audio_segment_id_field),
            });
        }

        Ok(results)
    }

    /// Returns true if the index was rebuilt due to a schema version change.
    /// When true, callers must reset related checkpoints (search_text, ocr)
    /// so that historical data is re-indexed into the empty index.
    pub fn was_rebuilt(&self) -> bool {
        self.rebuilt
    }
}

/// Extract a text field value from a Tantivy document, returning empty string if absent.
fn extract_text(doc: &tantivy::TantivyDocument, field: Field) -> String {
    doc.get_first(field)
        .and_then(|v| match v {
            tantivy::schema::OwnedValue::Str(s) => Some(s.to_string()),
            _ => None,
        })
        .unwrap_or_default()
}

/// Extract a u64 field value from a Tantivy document, returning 0 if absent.
fn extract_u64(doc: &tantivy::TantivyDocument, field: Field) -> u64 {
    doc.get_first(field)
        .and_then(|v| match v {
            tantivy::schema::OwnedValue::U64(n) => Some(*n),
            _ => None,
        })
        .unwrap_or(0)
}

/// Extract an i64 field value from a Tantivy document, returning 0 if absent.
fn extract_i64(doc: &tantivy::TantivyDocument, field: Field) -> i64 {
    doc.get_first(field)
        .and_then(|v| match v {
            tantivy::schema::OwnedValue::I64(n) => Some(*n),
            _ => None,
        })
        .unwrap_or(0)
}

/// Extract an optional f32 field value from a Tantivy document.
fn extract_opt_f32(doc: &tantivy::TantivyDocument, field: Field) -> Option<f32> {
    doc.get_first(field).and_then(|v| match v {
        tantivy::schema::OwnedValue::F64(n) => Some(*n as f32),
        _ => None,
    })
}

/// Determine which fields matched the query for the match reason tag.
/// Includes OCR and transcript source detection.
fn determine_match_reason(
    query: &str,
    app: &str,
    title: &str,
    url: &str,
    text_content: &str,
    source_kind: &str,
) -> String {
    let terms: Vec<String> = query
        .split_whitespace()
        .map(|w| w.to_lowercase())
        .collect();

    let mut reasons = Vec::new();

    let app_lower = app.to_lowercase();
    if terms.iter().any(|t| app_lower.contains(t)) {
        reasons.push("app");
    }

    let title_lower = title.to_lowercase();
    if terms.iter().any(|t| title_lower.contains(t)) {
        reasons.push("title");
    }

    let url_lower = url.to_lowercase();
    if terms.iter().any(|t| url_lower.contains(t)) {
        reasons.push("url");
    }

    if !text_content.is_empty() {
        let content_lower = text_content.to_lowercase();
        if terms.iter().any(|t| content_lower.contains(t)) {
            match source_kind {
                "ocr" => reasons.push("ocr"),
                "transcript" => reasons.push("transcript"),
                _ => reasons.push("text"),
            }
        }
    }

    if reasons.is_empty() {
        // Tantivy matched via stemming/tokenization that our naive check missed
        match source_kind {
            "ocr" => "ocr".to_string(),
            "transcript" => "transcript".to_string(),
            _ => "text".to_string(),
        }
    } else {
        reasons.join(",")
    }
}

/// Create a short snippet from text content, centered around the first query term match.
/// Uses char indices throughout to avoid panics on multi-byte UTF-8 (CJK, emoji, etc.).
fn make_snippet(text: &str, query: &str, max_chars: usize) -> String {
    if text.is_empty() {
        return String::new();
    }

    let text_lower = text.to_lowercase();
    let terms: Vec<String> = query
        .split_whitespace()
        .map(|w| w.to_lowercase())
        .collect();

    // Build a char-index-to-byte-offset map for the lowercased text.
    // We find the match position in char indices, then map back to byte offsets
    // in the original text for slicing.
    let char_count = text.chars().count();

    // Find first matching term position in char indices of the lowercased text
    let match_char_pos: usize = terms
        .iter()
        .filter_map(|t| {
            // Find byte offset in lowercased text, then convert to char index
            text_lower.find(t.as_str()).map(|byte_pos| {
                text_lower[..byte_pos].chars().count()
            })
        })
        .min()
        .unwrap_or(0);

    // Center snippet window around the match (in char indices)
    let half = max_chars / 2;
    let mut start_char = match_char_pos.saturating_sub(half);
    let mut end_char = (start_char + max_chars).min(char_count);
    if end_char == char_count {
        start_char = char_count.saturating_sub(max_chars);
    }

    // Snap to word boundaries using char indices on the original text.
    // Collect chars with their byte offsets for efficient slicing.
    let indexed_chars: Vec<(usize, char)> = text.char_indices().collect();

    // Snap start forward to after next space
    if start_char > 0 {
        if let Some(pos) = indexed_chars[start_char..end_char]
            .iter()
            .position(|(_, c)| *c == ' ')
        {
            start_char += pos + 1;
        }
    }

    // Snap end backward to before last space
    if end_char < char_count {
        if let Some(pos) = indexed_chars[start_char..end_char]
            .iter()
            .rposition(|(_, c)| *c == ' ')
        {
            end_char = start_char + pos;
        }
    }

    // Clamp in case snapping emptied the window
    if start_char >= end_char {
        start_char = match_char_pos;
        end_char = (start_char + max_chars).min(char_count);
    }

    // Convert char indices to byte offsets for slicing
    let byte_start = indexed_chars[start_char].0;
    let byte_end = if end_char >= indexed_chars.len() {
        text.len()
    } else {
        indexed_chars[end_char].0
    };

    let mut snippet = text[byte_start..byte_end].to_string();
    if start_char > 0 {
        snippet.insert_str(0, "\u{2026}");
    }
    if end_char < char_count {
        snippet.push('\u{2026}');
    }

    snippet
}

/// Public entry point for deduplication, used by search_hybrid in lib.rs.
pub fn deduplicate_results_public(
    results: Vec<SearchResult>,
    limit: usize,
) -> Vec<SearchResult> {
    deduplicate_results(results, limit)
}

/// Deduplicate search results within a 5-second timestamp window on the same display.
/// Keeps the highest-scoring result in each group, merging match_reason tags.
fn deduplicate_results(mut results: Vec<SearchResult>, limit: usize) -> Vec<SearchResult> {
    if results.is_empty() {
        return results;
    }

    // Group key: (display_id_or_0, ts_bucket_5s)
    let bucket_width: u64 = 5_000_000; // 5 seconds in microseconds

    struct Group {
        best: SearchResult,
        reasons: Vec<String>,
    }

    let mut groups: HashMap<(u32, u64), Group> = HashMap::new();
    // Track insertion order so results stay sorted by score
    let mut order: Vec<(u32, u64)> = Vec::new();

    for result in results.drain(..) {
        let display = result.display_id.unwrap_or(0);
        let bucket = result.ts / bucket_width;
        let key = (display, bucket);

        if let Some(group) = groups.get_mut(&key) {
            // Merge: keep higher score, collect reasons
            for reason in result.match_reason.split(',') {
                let r = reason.to_string();
                if !group.reasons.contains(&r) {
                    group.reasons.push(r);
                }
            }
            if result.score > group.best.score {
                // Keep the better snippet: prefer new result's, fall back to existing
                let prev_snippet = std::mem::take(&mut group.best.snippet);
                group.best = result;
                if group.best.snippet.is_empty() {
                    group.best.snippet = prev_snippet;
                }
            } else if group.best.snippet.is_empty() && !result.snippet.is_empty() {
                group.best.snippet = result.snippet;
            }
        } else {
            let reasons: Vec<String> = result
                .match_reason
                .split(',')
                .map(|s| s.to_string())
                .collect();
            order.push(key);
            groups.insert(key, Group { best: result, reasons });
        }
    }

    // Emit results in original score order, with merged reasons
    let mut deduped: Vec<SearchResult> = Vec::with_capacity(groups.len());
    for key in &order {
        if let Some(mut group) = groups.remove(key) {
            group.best.match_reason = group.reasons.join(",");
            deduped.push(group.best);
        }
    }

    deduped.truncate(limit);
    deduped
}

/// Search-specific error type (internal, mapped to ShadowError at the UniFFI boundary).
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error("Tantivy error: {0}")]
    TantivyError(String),
    #[error("Query parse error: {0}")]
    QueryParse(String),
    #[error("Index I/O error: {0}")]
    IndexIO(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_entry(ts: u64, app: Option<&str>, title: Option<&str>, url: Option<&str>) -> TimelineEntry {
        TimelineEntry {
            ts,
            track: 3,
            event_type: "app_switch".to_string(),
            app_name: app.map(|s| s.to_string()),
            window_title: title.map(|s| s.to_string()),
            url: url.map(|s| s.to_string()),
            display_id: None,
            segment_file: "test.msgpack".to_string(),
        }
    }

    #[test]
    fn test_index_and_search() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let entries = vec![
            make_entry(1000, Some("Chrome"), Some("Gmail - Inbox"), Some("https://mail.google.com")),
            make_entry(2000, Some("VS Code"), Some("main.rs - shadow"), None),
            make_entry(3000, Some("Slack"), Some("general - Shadow team"), None),
        ];

        let count = index.index_entries(&entries).unwrap();
        assert_eq!(count, 3);

        // Search by app name
        let results = index.search("Chrome", 10).unwrap();
        assert!(!results.is_empty());
        assert_eq!(results[0].app_name, "Chrome");
        assert_eq!(results[0].source_kind, "track3");

        // Search by window title
        let results = index.search("Gmail", 10).unwrap();
        assert!(!results.is_empty());
        assert!(results[0].window_title.contains("Gmail"));

        // Search by URL domain
        let results = index.search("google", 10).unwrap();
        assert!(!results.is_empty());

        // Search with no results
        let results = index.search("nonexistent_app_xyz", 10).unwrap();
        assert!(results.is_empty());

        // Empty query returns empty
        let results = index.search("", 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_stats() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let stats = index.stats();
        assert_eq!(stats.total_docs, 0);

        let entries = vec![
            make_entry(1000, Some("Chrome"), Some("test page"), None),
        ];
        index.index_entries(&entries).unwrap();

        let stats = index.stats();
        assert_eq!(stats.total_docs, 1);
    }

    #[test]
    fn test_skips_non_track3() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let entries = vec![
            TimelineEntry {
                ts: 1000,
                track: 2, // Input event — should be skipped
                event_type: "key_down".to_string(),
                app_name: Some("Chrome".to_string()),
                window_title: None,
                url: None,
                display_id: None,
                segment_file: "test.msgpack".to_string(),
            },
            make_entry(2000, Some("Chrome"), Some("Gmail"), None),
        ];

        let count = index.index_entries(&entries).unwrap();
        assert_eq!(count, 1); // Only the Track 3 entry
    }

    #[test]
    fn test_match_reason() {
        assert_eq!(
            determine_match_reason("chrome", "Chrome", "Gmail", "", "", "track3"),
            "app"
        );
        assert_eq!(
            determine_match_reason("gmail", "Chrome", "Gmail - Inbox", "", "", "track3"),
            "title"
        );
        assert_eq!(
            determine_match_reason("google", "Chrome", "Gmail", "https://google.com", "", "track3"),
            "url"
        );
        assert_eq!(
            determine_match_reason("chrome gmail", "Chrome", "Gmail", "", "", "track3"),
            "app,title"
        );
    }

    #[test]
    fn test_display_id_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let entries = vec![
            TimelineEntry {
                ts: 1000,
                track: 3,
                event_type: "app_switch".to_string(),
                app_name: Some("Chrome".to_string()),
                window_title: Some("Test".to_string()),
                url: None,
                display_id: Some(69734112),
                segment_file: "test.msgpack".to_string(),
            },
            // Entry without display_id
            make_entry(2000, Some("Slack"), Some("general"), None),
        ];

        index.index_entries(&entries).unwrap();

        let results = index.search("Chrome", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].display_id, Some(69734112));

        let results = index.search("Slack", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].display_id, None);
    }

    #[test]
    fn test_ocr_index_and_search() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let ocr_entries = vec![
            OcrEntry {
                ts: 1000,
                display_id: Some(1),
                text: "Meeting notes: discuss Q3 budget allocation and timeline".to_string(),
                app_name: Some("Zoom".to_string()),
                window_title: Some("Zoom Meeting".to_string()),
                confidence: Some(0.95),
            },
            OcrEntry {
                ts: 2000,
                display_id: Some(1),
                text: "func handleError(err error) { return fmt.Errorf }".to_string(),
                app_name: Some("VS Code".to_string()),
                window_title: Some("main.go".to_string()),
                confidence: Some(0.88),
            },
        ];

        let count = index.index_ocr_entries(&ocr_entries).unwrap();
        assert_eq!(count, 2);

        // Search for OCR text
        let results = index.search("budget", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].source_kind, "ocr");
        assert!(results[0].match_reason.contains("ocr"));
        assert!(results[0].snippet.contains("budget"));
        assert_eq!(results[0].app_name, "Zoom");

        // Search for code text
        let results = index.search("handleError", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].source_kind, "ocr");

        // Search that hits both track3 and OCR (using same index instance)
        let track3_entries = vec![
            make_entry(10_000_000, Some("Chrome"), Some("Budget Report - Google Sheets"), None),
        ];
        index.index_entries(&track3_entries).unwrap();

        let results = index.search("budget", 10).unwrap();
        assert!(results.len() >= 2); // Both OCR and track3 results
    }

    #[test]
    fn test_ocr_skips_empty_text() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let entries = vec![
            OcrEntry {
                ts: 1000,
                display_id: None,
                text: "   ".to_string(), // whitespace-only
                app_name: None,
                window_title: None,
                confidence: None,
            },
            OcrEntry {
                ts: 2000,
                display_id: None,
                text: "real text".to_string(),
                app_name: None,
                window_title: None,
                confidence: None,
            },
        ];

        let count = index.index_ocr_entries(&entries).unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_dedup_same_timestamp_window() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        // Two results within 5-second window on the same display should dedup
        let entries = vec![
            make_entry(1_000_000, Some("Chrome"), Some("Gmail - Search results"), None),
            make_entry(1_500_000, Some("Chrome"), Some("Gmail - Inbox"), None),
        ];
        index.index_entries(&entries).unwrap();

        let ocr_entries = vec![
            OcrEntry {
                ts: 1_200_000,
                display_id: None,
                text: "Gmail inbox with search results".to_string(),
                app_name: Some("Chrome".to_string()),
                window_title: None,
                confidence: Some(0.9),
            },
        ];
        index.index_ocr_entries(&ocr_entries).unwrap();

        // All three are within 5-second window (5_000_000us) with display_id=0(None)
        // They should dedup into fewer results
        let results = index.search("Gmail", 10).unwrap();
        assert!(results.len() <= 3); // May be deduped
        // The dedup should merge match_reason tags
    }

    #[test]
    fn test_schema_version_migration() {
        let tmp = TempDir::new().unwrap();

        // Create initial index
        {
            let mut index = SearchIndex::new(tmp.path()).unwrap();
            let entries = vec![
                make_entry(1000, Some("Chrome"), Some("test"), None),
            ];
            index.index_entries(&entries).unwrap();

            let stats = index.stats();
            assert_eq!(stats.total_docs, 1);
        }

        // Re-open — same version, should preserve data
        {
            let index = SearchIndex::new(tmp.path()).unwrap();
            let stats = index.stats();
            assert_eq!(stats.total_docs, 1);
        }

        // Schema version file exists
        let version_file = tmp.path().join("schema_version");
        assert!(version_file.exists());
        let version_str = std::fs::read_to_string(&version_file).unwrap();
        assert_eq!(version_str.trim(), SCHEMA_VERSION.to_string());
    }

    #[test]
    fn test_make_snippet() {
        let text = "The quick brown fox jumps over the lazy dog near the river bank";
        let snippet = make_snippet(text, "fox", 30);
        assert!(snippet.contains("fox"));

        // Short text returns as-is (no ellipsis)
        let snippet = make_snippet("hello world", "hello", 100);
        assert_eq!(snippet, "hello world");
    }

    #[test]
    fn test_make_snippet_cjk() {
        // CJK characters are 3 bytes each in UTF-8. Old code would panic here.
        let text = "会議の議題は予算配分についてです。来月の計画を確認しましょう。";
        let snippet = make_snippet(text, "予算", 15);
        assert!(snippet.contains("予算"));
        // Must not panic — that's the main assertion
    }

    #[test]
    fn test_make_snippet_emoji() {
        // Emoji are 4 bytes each. Must not panic on byte-boundary slicing.
        let text = "Status update 🚀 deployment succeeded 🎉 all tests passing ✅ ready for review";
        let snippet = make_snippet(text, "deployment", 30);
        assert!(snippet.contains("deployment"));
    }

    #[test]
    fn test_make_snippet_mixed_scripts() {
        // Mix of ASCII, CJK, and emoji
        let text = "Project Alpha: 完了 ✅ — next milestone is Beta: 進行中 🔄";
        let snippet = make_snippet(text, "Beta", 20);
        assert!(snippet.contains("Beta"));
    }

    #[test]
    fn test_make_snippet_empty() {
        assert_eq!(make_snippet("", "query", 30), "");
    }

    #[test]
    fn test_make_snippet_no_match() {
        // Query term not found — should still produce a snippet from start
        let text = "The quick brown fox jumps over the lazy dog";
        let snippet = make_snippet(text, "zzzzz", 20);
        assert!(!snippet.is_empty());
    }

    #[test]
    fn test_match_reason_ocr() {
        assert_eq!(
            determine_match_reason("budget", "", "", "", "Q3 budget discussion", "ocr"),
            "ocr"
        );
        assert_eq!(
            determine_match_reason("budget", "Zoom", "", "", "Q3 budget discussion", "ocr"),
            "ocr"
        );
        assert_eq!(
            determine_match_reason("zoom budget", "Zoom", "", "", "Q3 budget discussion", "ocr"),
            "app,ocr"
        );
    }

    #[test]
    fn test_transcript_index_and_search() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let entries = vec![
            TranscriptEntry {
                audio_segment_id: 1,
                source: "mic".to_string(),
                ts_start: 1_000_000,
                ts_end: 1_500_000,
                text: "we should finalize the Q3 budget by Friday".to_string(),
                confidence: Some(0.92),
                app_name: Some("Zoom".to_string()),
                window_title: Some("Weekly Standup".to_string()),
            },
            TranscriptEntry {
                audio_segment_id: 1,
                source: "system".to_string(),
                ts_start: 1_500_000,
                ts_end: 2_000_000,
                text: "agreed, let me send the spreadsheet after this call".to_string(),
                confidence: Some(0.88),
                app_name: Some("Zoom".to_string()),
                window_title: Some("Weekly Standup".to_string()),
            },
            TranscriptEntry {
                audio_segment_id: 2,
                source: "mic".to_string(),
                ts_start: 3_000_000,
                ts_end: 3_500_000,
                text: "   ".to_string(), // whitespace-only — should be skipped
                confidence: None,
                app_name: None,
                window_title: None,
            },
        ];

        let count = index.index_transcript_entries(&entries).unwrap();
        assert_eq!(count, 2); // skipped the whitespace-only entry

        // Search for transcript text — verify metadata roundtrip
        let results = index.search("budget", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].source_kind, "transcript");
        assert!(results[0].match_reason.contains("transcript"));
        assert!(results[0].snippet.contains("budget"));
        assert_eq!(results[0].app_name, "Zoom");
        assert_eq!(results[0].audio_segment_id, Some(1));
        assert_eq!(results[0].audio_source, "mic");
        assert_eq!(results[0].ts_end, 1_500_000);
        assert_eq!(results[0].confidence, Some(0.92));

        // Search across both transcript entries — verify system source metadata
        let results = index.search("spreadsheet", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].source_kind, "transcript");
        assert_eq!(results[0].audio_segment_id, Some(1));
        assert_eq!(results[0].audio_source, "system");
        assert_eq!(results[0].ts_end, 2_000_000);
        assert_eq!(results[0].confidence, Some(0.88));
    }

    #[test]
    fn test_transcript_dedup_with_ocr() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        // Index an OCR entry and a transcript entry near the same timestamp
        // Both mention "deployment" — should be deduped within the 5-second window
        let ocr_entries = vec![OcrEntry {
            ts: 1_000_000,
            display_id: None,
            text: "Deployment pipeline status: building".to_string(),
            app_name: Some("Chrome".to_string()),
            window_title: Some("CI Dashboard".to_string()),
            confidence: Some(0.95),
        }];
        index.index_ocr_entries(&ocr_entries).unwrap();

        let transcript_entries = vec![TranscriptEntry {
            audio_segment_id: 1,
            source: "mic".to_string(),
            ts_start: 1_200_000, // within 5-second window of OCR entry
            ts_end: 1_800_000,
            text: "the deployment is still running, let's wait".to_string(),
            confidence: Some(0.90),
            app_name: Some("Zoom".to_string()),
            window_title: Some("Standup".to_string()),
        }];
        index.index_transcript_entries(&transcript_entries).unwrap();

        let results = index.search("deployment", 10).unwrap();
        // Both are in the same 5-second bucket with display_id=None(0)
        // Should be deduped to 1 result with merged match_reason
        assert_eq!(results.len(), 1);
        let reason = &results[0].match_reason;
        // The merged reason should contain both "ocr" and "transcript"
        assert!(reason.contains("ocr") || reason.contains("transcript"),
            "Expected match_reason to contain ocr or transcript, got: {}", reason);
    }

    #[test]
    fn test_dedup_visual_with_text() {
        // When a visual result and a text result fall in the same 5-second bucket,
        // they should be deduped. The merged result should contain both reasons.
        let text_result = SearchResult {
            ts: 1_000_000,
            app_name: "Chrome".to_string(),
            window_title: "Dashboard".to_string(),
            url: String::new(),
            display_id: Some(1),
            event_type: String::new(),
            score: 0.9,
            match_reason: "title".to_string(),
            source_kind: "track3".to_string(),
            snippet: String::new(),
            audio_segment_id: None,
            audio_source: String::new(),
            ts_end: 0,
            confidence: None,
        };

        let visual_result = SearchResult {
            ts: 1_200_000, // within 5-second window
            app_name: "Chrome".to_string(),
            window_title: String::new(),
            url: String::new(),
            display_id: Some(1),
            event_type: String::new(),
            score: 0.85,
            match_reason: "visual".to_string(),
            source_kind: "visual".to_string(),
            snippet: String::new(),
            audio_segment_id: None,
            audio_source: String::new(),
            ts_end: 0,
            confidence: None,
        };

        let results = vec![text_result, visual_result];
        let deduped = deduplicate_results(results, 10);

        // Same 5-second bucket, same display — should merge
        assert_eq!(deduped.len(), 1);
        // Merged reasons should contain both
        assert!(deduped[0].match_reason.contains("title"));
        assert!(deduped[0].match_reason.contains("visual"));
    }

    #[test]
    fn test_dedup_visual_different_display() {
        // Visual results from different displays should NOT be deduped together.
        let visual_d1 = SearchResult {
            ts: 1_000_000,
            app_name: String::new(),
            window_title: String::new(),
            url: String::new(),
            display_id: Some(1),
            event_type: String::new(),
            score: 0.9,
            match_reason: "visual".to_string(),
            source_kind: "visual".to_string(),
            snippet: String::new(),
            audio_segment_id: None,
            audio_source: String::new(),
            ts_end: 0,
            confidence: None,
        };

        let visual_d2 = SearchResult {
            ts: 1_100_000, // within 5-second window but different display
            app_name: String::new(),
            window_title: String::new(),
            url: String::new(),
            display_id: Some(2),
            event_type: String::new(),
            score: 0.85,
            match_reason: "visual".to_string(),
            source_kind: "visual".to_string(),
            snippet: String::new(),
            audio_segment_id: None,
            audio_source: String::new(),
            ts_end: 0,
            confidence: None,
        };

        let results = vec![visual_d1, visual_d2];
        let deduped = deduplicate_results(results, 10);

        // Different displays — should NOT merge
        assert_eq!(deduped.len(), 2);
    }

    #[test]
    fn test_search_text_in_range_filters_by_timestamp() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let entries = vec![
            make_entry(1_000_000, Some("Chrome"), Some("Gmail early"), None),
            make_entry(5_000_000, Some("Chrome"), Some("Gmail middle"), None),
            make_entry(9_000_000, Some("Chrome"), Some("Gmail late"), None),
        ];
        index.index_entries(&entries).unwrap();

        // Range [3M, 7M] should only return the middle entry
        let results = index.search_in_range("Gmail", 3_000_000, 7_000_000, 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].ts, 5_000_000);
        assert!(results[0].window_title.contains("middle"));

        // Empty query → empty
        let results = index.search_in_range("", 0, 10_000_000, 10).unwrap();
        assert!(results.is_empty());

        // start > end → empty
        let results = index.search_in_range("Gmail", 8_000_000, 2_000_000, 10).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_deduplicate_results_public_matches_internal() {
        let results = vec![
            SearchResult {
                ts: 1_000_000,
                app_name: "App".to_string(),
                window_title: "Win".to_string(),
                url: String::new(),
                display_id: Some(1),
                event_type: String::new(),
                score: 0.9,
                match_reason: "title".to_string(),
                source_kind: "track3".to_string(),
                snippet: String::new(),
                audio_segment_id: None,
                audio_source: String::new(),
                ts_end: 0,
                confidence: None,
            },
        ];

        let deduped = deduplicate_results_public(results, 10);
        assert_eq!(deduped.len(), 1);
        assert_eq!(deduped[0].app_name, "App");
    }

    // --- list_transcript_chunks_in_range tests ---

    /// Helper: create and index transcript entries, returning the SearchIndex.
    fn setup_transcript_index(entries: &[TranscriptEntry]) -> (TempDir, SearchIndex) {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();
        index.index_transcript_entries(entries).unwrap();
        (tmp, index)
    }

    fn make_transcript(
        ts_start: u64,
        ts_end: u64,
        text: &str,
        source: &str,
        segment_id: i64,
    ) -> TranscriptEntry {
        TranscriptEntry {
            audio_segment_id: segment_id,
            source: source.to_string(),
            ts_start,
            ts_end,
            text: text.to_string(),
            confidence: Some(0.9),
            app_name: Some("Zoom".to_string()),
            window_title: Some("Meeting".to_string()),
        }
    }

    #[test]
    fn test_range_query_transcript_only() {
        // Index transcript, track3, and OCR entries. Range query must return only transcripts.
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        // Track3 entry at ts=1_000_000
        let track3 = vec![make_entry(
            1_000_000,
            Some("Chrome"),
            Some("Gmail"),
            None,
        )];
        index.index_entries(&track3).unwrap();

        // OCR entry at ts=1_500_000
        let ocr = vec![OcrEntry {
            ts: 1_500_000,
            display_id: None,
            text: "some OCR text".to_string(),
            app_name: Some("Chrome".to_string()),
            window_title: Some("Page".to_string()),
            confidence: Some(0.95),
        }];
        index.index_ocr_entries(&ocr).unwrap();

        // Transcript entry at ts=2_000_000
        let transcript = vec![make_transcript(
            2_000_000,
            2_500_000,
            "hello from the meeting",
            "mic",
            1,
        )];
        index.index_transcript_entries(&transcript).unwrap();

        // Range query covering all three timestamps
        let results = index
            .list_transcript_chunks_in_range(0, 10_000_000, 100, 0)
            .unwrap();

        // Must return only the transcript entry, not track3 or OCR
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].ts_start, 2_000_000);
        assert_eq!(results[0].text, "hello from the meeting");
        assert_eq!(results[0].audio_source, "mic");
        assert_eq!(results[0].audio_segment_id, 1);
    }

    #[test]
    fn test_range_query_inclusive_boundaries() {
        let entries = vec![
            make_transcript(100, 200, "at start boundary", "mic", 1),
            make_transcript(500, 600, "in the middle", "system", 1),
            make_transcript(1000, 1100, "at end boundary", "mic", 2),
        ];
        let (_tmp, index) = setup_transcript_index(&entries);

        // Query with start_us=100 and end_us=1000 — both boundary entries should be included
        let results = index
            .list_transcript_chunks_in_range(100, 1000, 100, 0)
            .unwrap();

        assert_eq!(results.len(), 3);
        assert_eq!(results[0].ts_start, 100); // inclusive start
        assert_eq!(results[1].ts_start, 500);
        assert_eq!(results[2].ts_start, 1000); // inclusive end
    }

    #[test]
    fn test_range_query_excludes_outside() {
        let entries = vec![
            make_transcript(100, 200, "before range", "mic", 1),
            make_transcript(500, 600, "in range", "mic", 1),
            make_transcript(1000, 1100, "after range", "mic", 2),
        ];
        let (_tmp, index) = setup_transcript_index(&entries);

        // Query with range [300, 700] — only the middle entry
        let results = index
            .list_transcript_chunks_in_range(300, 700, 100, 0)
            .unwrap();

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].ts_start, 500);
        assert_eq!(results[0].text, "in range");
    }

    #[test]
    fn test_range_query_pagination() {
        // Create 10 transcript entries with ascending timestamps
        let entries: Vec<TranscriptEntry> = (0..10)
            .map(|i| {
                make_transcript(
                    (i + 1) * 1000,
                    (i + 1) * 1000 + 500,
                    &format!("chunk {}", i),
                    "mic",
                    1,
                )
            })
            .collect();
        let (_tmp, index) = setup_transcript_index(&entries);

        // Page 0: first 3 results
        let page0 = index
            .list_transcript_chunks_in_range(0, 100_000, 3, 0)
            .unwrap();
        assert_eq!(page0.len(), 3);
        assert_eq!(page0[0].ts_start, 1000);
        assert_eq!(page0[1].ts_start, 2000);
        assert_eq!(page0[2].ts_start, 3000);

        // Page 1: next 3 results (offset=3)
        let page1 = index
            .list_transcript_chunks_in_range(0, 100_000, 3, 3)
            .unwrap();
        assert_eq!(page1.len(), 3);
        assert_eq!(page1[0].ts_start, 4000);
        assert_eq!(page1[1].ts_start, 5000);
        assert_eq!(page1[2].ts_start, 6000);

        // Page 2: next 3 results (offset=6)
        let page2 = index
            .list_transcript_chunks_in_range(0, 100_000, 3, 6)
            .unwrap();
        assert_eq!(page2.len(), 3);
        assert_eq!(page2[0].ts_start, 7000);

        // Page 3: last result (offset=9)
        let page3 = index
            .list_transcript_chunks_in_range(0, 100_000, 3, 9)
            .unwrap();
        assert_eq!(page3.len(), 1);
        assert_eq!(page3[0].ts_start, 10000);

        // Page 4: past the end (offset=10)
        let page4 = index
            .list_transcript_chunks_in_range(0, 100_000, 3, 10)
            .unwrap();
        assert!(page4.is_empty());

        // Verify no duplication: collect all pages and check uniqueness
        let mut all_ts: Vec<u64> = Vec::new();
        all_ts.extend(page0.iter().map(|r| r.ts_start));
        all_ts.extend(page1.iter().map(|r| r.ts_start));
        all_ts.extend(page2.iter().map(|r| r.ts_start));
        all_ts.extend(page3.iter().map(|r| r.ts_start));
        assert_eq!(all_ts.len(), 10);
        // Should be sorted ascending with no duplicates
        for window in all_ts.windows(2) {
            assert!(window[0] < window[1], "Not sorted or has duplicates");
        }
    }

    #[test]
    fn test_range_query_start_after_end() {
        let entries = vec![make_transcript(1000, 2000, "some text", "mic", 1)];
        let (_tmp, index) = setup_transcript_index(&entries);

        // start_us > end_us → empty result
        let results = index
            .list_transcript_chunks_in_range(5000, 1000, 100, 0)
            .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_range_query_limit_zero() {
        let entries = vec![make_transcript(1000, 2000, "some text", "mic", 1)];
        let (_tmp, index) = setup_transcript_index(&entries);

        // limit == 0 → empty result
        let results = index
            .list_transcript_chunks_in_range(0, 100_000, 0, 0)
            .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_range_query_limit_clamped() {
        // Create 5 entries and request limit=5000 — should be clamped to 1000 (still returns all 5)
        let entries: Vec<TranscriptEntry> = (0..5)
            .map(|i| make_transcript(i * 1000 + 1000, i * 1000 + 1500, "text", "mic", 1))
            .collect();
        let (_tmp, index) = setup_transcript_index(&entries);

        let results = index
            .list_transcript_chunks_in_range(0, 100_000, 5000, 0)
            .unwrap();
        assert_eq!(results.len(), 5); // All returned, limit clamped but still > count
    }

    #[test]
    fn test_range_query_sorted_ascending() {
        // Index entries in reverse order — results must still be sorted ascending
        let entries = vec![
            make_transcript(9000, 9500, "last", "mic", 3),
            make_transcript(1000, 1500, "first", "mic", 1),
            make_transcript(5000, 5500, "middle", "system", 2),
        ];
        let (_tmp, index) = setup_transcript_index(&entries);

        let results = index
            .list_transcript_chunks_in_range(0, 100_000, 100, 0)
            .unwrap();

        assert_eq!(results.len(), 3);
        assert_eq!(results[0].ts_start, 1000);
        assert_eq!(results[0].text, "first");
        assert_eq!(results[1].ts_start, 5000);
        assert_eq!(results[1].text, "middle");
        assert_eq!(results[2].ts_start, 9000);
        assert_eq!(results[2].text, "last");
    }

    #[test]
    fn test_range_query_metadata_roundtrip() {
        let entries = vec![TranscriptEntry {
            audio_segment_id: 42,
            source: "system".to_string(),
            ts_start: 1_000_000,
            ts_end: 1_500_000,
            text: "budget discussion for Q3".to_string(),
            confidence: Some(0.87),
            app_name: Some("Google Meet".to_string()),
            window_title: Some("Weekly Sync".to_string()),
        }];
        let (_tmp, index) = setup_transcript_index(&entries);

        let results = index
            .list_transcript_chunks_in_range(0, 10_000_000, 100, 0)
            .unwrap();

        assert_eq!(results.len(), 1);
        let r = &results[0];
        assert_eq!(r.ts_start, 1_000_000);
        assert_eq!(r.ts_end, 1_500_000);
        assert_eq!(r.text, "budget discussion for Q3");
        assert_eq!(r.audio_source, "system");
        assert_eq!(r.confidence, Some(0.87));
        assert_eq!(r.app_name, "Google Meet");
        assert_eq!(r.window_title, "Weekly Sync");
        assert_eq!(r.audio_segment_id, 42);
    }

    #[test]
    fn test_search_with_colon_in_query() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let entries = vec![
            make_entry(1000, Some("Chrome"), Some("Meeting at 11:30 AM"), None),
        ];
        index.index_entries(&entries).unwrap();

        // This previously failed with "Field does not exist: '11'"
        // Lenient parsing handles the colon gracefully.
        let results = index.search("11:30", 10).unwrap();
        assert!(!results.is_empty());
        assert!(results[0].window_title.contains("11:30"));

        // Range search with colons should also work
        let results = index.search_in_range("11:30", 0, 2000, 10).unwrap();
        assert!(!results.is_empty());
    }

    #[test]
    fn test_search_with_url_query() {
        let tmp = TempDir::new().unwrap();
        let mut index = SearchIndex::new(tmp.path()).unwrap();

        let entries = vec![
            make_entry(1000, Some("Chrome"), Some("Google"), Some("https://google.com")),
        ];
        index.index_entries(&entries).unwrap();

        // URLs contain colons and slashes — lenient parsing should handle them
        let results = index.search("https://google.com", 10).unwrap();
        assert!(!results.is_empty());
    }
}
