import SwiftUI

/// Developer diagnostics panel showing capture health metrics.
struct DiagnosticsView: View {
    @State private var snapshot = DiagnosticsStore.shared.snapshot()
    @State private var refreshTimer: Timer?

    // Dependencies injected from ShadowApp. Closures/accessors rather than
    // captured values because llmOrchestrator and summaryJobQueue may be nil
    // at view creation time and become available later.
    var currentLLMOrchestrator: (@MainActor () -> LLMOrchestrator?) = { nil }
    var currentSummaryJobQueue: (@MainActor () -> SummaryJobQueue?) = { nil }
    var showProactiveInbox: (@MainActor () -> Void) = {}
    var showProactiveActivity: (@MainActor () -> Void) = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusSection
                ingestSection
                searchSection
                ocrSection
                vectorSection
                transcriptSection
                audioSection
                audioPlaybackSection
                audioTimelineTapSection
                correlationSection
                intelligenceSection
                proactiveSection
                storageSection
                warningsSection
                actionsSection
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 500)
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] _ in
                Task { @MainActor in
                    self.snapshot = DiagnosticsStore.shared.snapshot()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Status Summary

    private var statusSection: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle()
                        .fill(healthColor)
                        .frame(width: 10, height: 10)
                    Text(healthLabel)
                        .font(.headline)
                    Spacer()
                    if let sessionId = EventWriter.clock?.sessionId {
                        Text(sessionId.prefix(8))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Text("Events received:")
                    Spacer()
                    Text("\(snapshot.counters["ingest_events_received_total", default: 0])")
                        .monospacedDigit()
                }
                HStack {
                    Text("Events written:")
                    Spacer()
                    Text("\(snapshot.counters["ingest_events_written_total", default: 0])")
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Ingest Health

    private var ingestSection: some View {
        GroupBox("Ingest Health") {
            VStack(alignment: .leading, spacing: 6) {
                metricRow("Queue depth", value: "\(Int(snapshot.gauges["ingest_queue_depth_current", default: 0]))")
                metricRow("Queue high-water", value: "\(snapshot.highWaterMarks["ingest_queue_depth_high_watermark", default: 0])")
                metricRow("Dropped events", value: "\(snapshot.counters["ingest_events_dropped_total", default: 0])")
                metricRow("Batch write fails", value: "\(snapshot.counters["ingest_batch_write_fail_total", default: 0])")
                metricRow("Write latency p50", value: String(format: "%.1fms", snapshot.latencyP50["ingest_batch_write_ms", default: 0]))
                metricRow("Write latency p95", value: String(format: "%.1fms", snapshot.latencyP95["ingest_batch_write_ms", default: 0]))
            }
        }
    }

    // MARK: - Search Health

    private var searchSection: some View {
        GroupBox("Search") {
            VStack(alignment: .leading, spacing: 6) {
                metricRow("Queries total", value: "\(snapshot.counters["search_queries_total", default: 0])")
                metricRow("Results returned", value: "\(snapshot.counters["search_results_returned_total", default: 0])")
                metricRow("Results opened", value: "\(snapshot.counters["search_result_opened_total", default: 0])")
                metricRow("Query failures", value: "\(snapshot.counters["search_query_fail_total", default: 0])")
                metricRow("Query latency p50", value: String(format: "%.1fms", snapshot.latencyP50["search_query_ms", default: 0]))
                metricRow("Query latency p95", value: String(format: "%.1fms", snapshot.latencyP95["search_query_ms", default: 0]))
            }
        }
    }

    // MARK: - OCR Health

    private var ocrSection: some View {
        GroupBox("OCR Pipeline") {
            VStack(alignment: .leading, spacing: 6) {
                metricRow("Frames processed", value: "\(snapshot.counters["ocr_frames_processed_total", default: 0])")
                metricRow("Frames deduped", value: "\(snapshot.counters["ocr_frames_deduped_total", default: 0])")
                metricRow("Entries indexed", value: "\(snapshot.counters["ocr_entries_indexed_total", default: 0])")
                metricRow("Process failures", value: "\(snapshot.counters["ocr_process_fail_total", default: 0])")
                metricRow("Recognition failures", value: "\(snapshot.counters["ocr_recognition_fail_total", default: 0])")
                metricRow("File missing", value: "\(snapshot.counters["ocr_file_missing_total", default: 0])")
                metricRow("Batch latency p50", value: String(format: "%.0fms", snapshot.latencyP50["ocr_batch_ms", default: 0]))
                metricRow("Batch latency p95", value: String(format: "%.0fms", snapshot.latencyP95["ocr_batch_ms", default: 0]))
            }
        }
    }

    // MARK: - Vector Pipeline

    private var vectorSection: some View {
        GroupBox("Vector Pipeline (CLIP)") {
            VStack(alignment: .leading, spacing: 10) {
                // Model status
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Model")
                            .font(.callout.bold())
                        Spacer()
                        Circle()
                            .fill(snapshot.gauges["vector_model_loaded", default: 0] > 0 ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text(snapshot.gauges["vector_model_loaded", default: 0] > 0 ? "Loaded" : "Not loaded")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    metricRow("Load success", value: "\(snapshot.counters["model_load_success_total", default: 0])")
                    metricRow("Load failures", value: "\(snapshot.counters["model_load_fail_total", default: 0])")
                }

                Divider()

                // Indexing metrics
                VStack(alignment: .leading, spacing: 6) {
                    Text("Indexing")
                        .font(.callout.bold())
                    metricRow("Frames received", value: "\(snapshot.counters["vector_frames_received_total", default: 0])")
                    metricRow("Frames deduped", value: "\(snapshot.counters["vector_frames_deduped_total", default: 0])")
                    metricRow("Entries indexed", value: "\(snapshot.counters["vector_entries_indexed_total", default: 0])")
                    metricRow("Embed inference fails", value: "\(snapshot.counters["vector_embed_infer_fail_total", default: 0])")
                    metricRow("Process failures", value: "\(snapshot.counters["vector_process_fail_total", default: 0])")
                    metricRow("File missing", value: "\(snapshot.counters["vector_file_missing_total", default: 0])")
                    metricRow("Batch latency p50", value: String(format: "%.0fms", snapshot.latencyP50["vector_batch_ms", default: 0]))
                    metricRow("Batch latency p95", value: String(format: "%.0fms", snapshot.latencyP95["vector_batch_ms", default: 0]))
                }

                Divider()

                // Query encoding metrics
                VStack(alignment: .leading, spacing: 6) {
                    Text("Query Encoding")
                        .font(.callout.bold())
                    metricRow("Encode attempts", value: "\(snapshot.counters["vector_query_encode_attempt_total", default: 0])")
                    metricRow("Encode success", value: "\(snapshot.counters["vector_query_encode_success_total", default: 0])")
                    metricRow("Encode failures", value: "\(snapshot.counters["vector_query_encode_fail_total", default: 0])")
                    metricRow("Cache hits", value: "\(snapshot.counters["vector_query_cache_hit_total", default: 0])")
                    metricRow("Cache misses", value: "\(snapshot.counters["vector_query_cache_miss_total", default: 0])")
                }
            }
        }
    }

    // MARK: - Transcript Pipeline

    private var transcriptSection: some View {
        GroupBox("Transcript Pipeline") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    metricRow("Segments processed", value: "\(snapshot.counters["transcript_segments_processed_total", default: 0])")
                    metricRow("Chunks indexed", value: "\(snapshot.counters["transcript_chunks_indexed_total", default: 0])")
                    metricRow("Segments empty (no speech)", value: "\(snapshot.counters["transcript_segments_empty_total", default: 0])")
                    metricRow("Segments retried", value: "\(snapshot.counters["transcript_segments_retried_total", default: 0])")
                    metricRow("Segments skipped (max retries)", value: "\(snapshot.counters["transcript_segments_skipped_total", default: 0])")
                    metricRow("Recognition failures", value: "\(snapshot.counters["transcript_recognition_fail_total", default: 0])")
                    metricRow("Process failures", value: "\(snapshot.counters["transcript_process_fail_total", default: 0])")
                    metricRow("File missing", value: "\(snapshot.counters["transcript_file_missing_total", default: 0])")
                    metricRow("Bad input (corrupt)", value: "\(snapshot.counters["transcript_bad_input_total", default: 0])")
                    metricRow("Backlog segments", value: "\(Int(snapshot.gauges["transcript_backlog_segments", default: 0]))")
                    metricRow("Batch latency p50", value: String(format: "%.0fms", snapshot.latencyP50["transcript_batch_ms", default: 0]))
                    metricRow("Batch latency p95", value: String(format: "%.0fms", snapshot.latencyP95["transcript_batch_ms", default: 0]))
                }

                Divider()

                // Provider subsection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider")
                        .font(.callout.bold())

                    HStack {
                        Text("Whisper model")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Circle()
                            .fill(snapshot.gauges["whisper_model_loaded", default: 0] > 0 ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text(snapshot.gauges["whisper_model_loaded", default: 0] > 0 ? "Loaded" : "Not loaded")
                            .monospacedDigit()
                    }
                    .font(.callout)

                    metricRow("Active profile", value: snapshot.stringGauges["whisper_active_profile"] ?? "\u{2014}")
                    metricRow("Model ID", value: snapshot.stringGauges["whisper_active_model_id"] ?? "\u{2014}")

                    Divider()

                    metricRow("Whisper attempts", value: "\(snapshot.counters["transcript_provider_whisper_attempt_total", default: 0])")
                    metricRow("Whisper success", value: "\(snapshot.counters["transcript_provider_whisper_success_total", default: 0])")
                    metricRow("Whisper failures", value: "\(snapshot.counters["transcript_provider_whisper_fail_total", default: 0])")
                    metricRow("Whisper unavailable", value: "\(snapshot.counters["transcript_provider_whisper_unavailable_total", default: 0])")
                    metricRow("Whisper transient", value: "\(snapshot.counters["transcript_provider_whisper_transient_total", default: 0])")
                    metricRow("Apple attempts", value: "\(snapshot.counters["transcript_provider_apple_speech_attempt_total", default: 0])")
                    metricRow("Apple success", value: "\(snapshot.counters["transcript_provider_apple_speech_success_total", default: 0])")
                    metricRow("Apple failures", value: "\(snapshot.counters["transcript_provider_apple_speech_fail_total", default: 0])")
                    metricRow("Fallback to Apple (Whisper\u{2192}Apple)", value: "\(snapshot.counters["transcript_provider_fallback_to_apple_total", default: 0])")
                    metricRow("No provider available", value: "\(snapshot.counters["transcript_no_provider_available_total", default: 0])")
                }
            }
        }
    }

    // MARK: - Audio Health

    private var audioSection: some View {
        GroupBox("Audio Capture") {
            VStack(alignment: .leading, spacing: 10) {
                // Mic capture metrics
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Mic")
                            .font(.callout.bold())
                        Spacer()
                        Circle()
                            .fill(snapshot.gauges["audio_capture_active", default: 0] > 0 ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text(snapshot.gauges["audio_capture_active", default: 0] > 0 ? "Active" : "Idle")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    metricRow("Segments opened", value: "\(snapshot.counters["audio_segments_opened_total", default: 0])")
                    metricRow("Segments closed", value: "\(snapshot.counters["audio_segments_closed_total", default: 0])")
                    metricRow("Capture failures", value: "\(snapshot.counters["audio_capture_fail_total", default: 0])")
                }

                Divider()

                // System audio metrics
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("System")
                            .font(.callout.bold())
                        Spacer()
                        Circle()
                            .fill(snapshot.gauges["system_audio_capture_active", default: 0] > 0 ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text(snapshot.gauges["system_audio_capture_active", default: 0] > 0 ? "Active" : "Idle")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    metricRow("Segments opened", value: "\(snapshot.counters["system_audio_segments_opened_total", default: 0])")
                    metricRow("Segments closed", value: "\(snapshot.counters["system_audio_segments_closed_total", default: 0])")
                    metricRow("Capture failures", value: "\(snapshot.counters["system_audio_capture_fail_total", default: 0])")
                }

                // Shared metrics
                metricRow("Orphans finalized", value: "\(snapshot.counters["audio_orphan_closed_total", default: 0])")
            }
        }
    }

    // MARK: - Audio Playback

    private var audioPlaybackSection: some View {
        GroupBox("Audio Playback") {
            VStack(alignment: .leading, spacing: 6) {
                // Live state
                HStack {
                    Text("State")
                        .foregroundStyle(.secondary)
                    Spacer()
                    let player = AudioPlayer.shared
                    Circle()
                        .fill(player.isPlaying ? Color.green : (player.isPaused ? Color.yellow : Color.secondary.opacity(0.3)))
                        .frame(width: 8, height: 8)
                    Text(player.isPlaying ? "Playing" : (player.isPaused ? "Paused" : "Idle"))
                        .monospacedDigit()
                }
                .font(.callout)
                metricRow("Segment", value: AudioPlayer.shared.currentSegmentId.map { "\($0)" } ?? "\u{2014}")
                metricRow("Source", value: AudioPlayer.shared.currentSource ?? "\u{2014}")
                metricRow("Position", value: formatPlaybackPosition())

                Divider()

                // Persistent counters
                metricRow("Attempts", value: "\(snapshot.counters["audio_playback_attempt_total", default: 0])")
                metricRow("Successes", value: "\(snapshot.counters["audio_playback_success_total", default: 0])")
                metricRow("Failures", value: "\(snapshot.counters["audio_playback_fail_total", default: 0])")
                metricRow("Missing segments", value: "\(snapshot.counters["audio_playback_missing_segment_total", default: 0])")
            }
        }
    }

    private func formatPlaybackPosition() -> String {
        let player = AudioPlayer.shared
        guard player.isPlaying || player.isPaused else { return "\u{2014}" }
        let cur = Int(player.currentTime)
        let dur = Int(player.duration)
        return String(format: "%d:%02d / %d:%02d", cur / 60, cur % 60, dur / 60, dur % 60)
    }

    // MARK: - Audio Timeline Tap

    private var audioTimelineTapSection: some View {
        GroupBox("Audio Timeline Tap") {
            VStack(alignment: .leading, spacing: 6) {
                metricRow("Taps (total)", value: "\(snapshot.counters["audio_timeline_tap_total", default: 0])")
                metricRow("In audio track", value: "\(snapshot.counters["audio_timeline_tap_in_track_total", default: 0])")

                Divider()

                metricRow("In mic row", value: "\(snapshot.counters["audio_timeline_tap_in_mic_total", default: 0])")
                metricRow("In system row", value: "\(snapshot.counters["audio_timeline_tap_in_system_total", default: 0])")

                Divider()

                metricRow("Hit segment", value: "\(snapshot.counters["audio_timeline_tap_hit_segment_total", default: 0])")
                metricRow("Miss segment", value: "\(snapshot.counters["audio_timeline_tap_miss_segment_total", default: 0])")
                metricRow("Play started", value: "\(snapshot.counters["audio_timeline_play_start_total", default: 0])")
            }
        }
    }

    // MARK: - Correlation Health

    private var correlationSection: some View {
        GroupBox("Correlation Health") {
            VStack(alignment: .leading, spacing: 6) {
                metricRow("Display unknown", value: "\(snapshot.counters["display_id_unknown_total", default: 0])")
                metricRow("Frame: no segment", value: "\(snapshot.counters["frame_no_segment_total", default: 0])")
                metricRow("Frame: lookup error", value: "\(snapshot.counters["frame_lookup_error_total", default: 0])")
                metricRow("Frame: file missing", value: "\(snapshot.counters["frame_file_missing_total", default: 0])")
                metricRow("Frame: decode error", value: "\(snapshot.counters["frame_decode_fail_total", default: 0])")
                metricRow("Index insert fails", value: "\(snapshot.counters["timeline_index_insert_fail_total", default: 0])")
            }
        }
    }

    // MARK: - Storage & Retention

    private var storageSection: some View {
        GroupBox("Storage & Retention") {
            VStack(alignment: .leading, spacing: 6) {
                // Per-component breakdown
                HStack {
                    Text("Video:")
                    Spacer()
                    Text(formatGB(snapshot.gauges["storage_video_gb", default: 0]))
                        .monospacedDigit()
                }
                HStack {
                    Text("Audio:")
                    Spacer()
                    Text(formatGB(snapshot.gauges["storage_audio_gb", default: 0]))
                        .monospacedDigit()
                }
                HStack {
                    Text("Keyframes:")
                    Spacer()
                    Text(formatGB(snapshot.gauges["storage_keyframes_gb", default: 0]))
                        .monospacedDigit()
                }
                HStack {
                    Text("Indices:")
                    Spacer()
                    Text(formatGB(snapshot.gauges["storage_indices_gb", default: 0]))
                        .monospacedDigit()
                }
                HStack {
                    Text("Events:")
                    Spacer()
                    Text(formatGB(snapshot.gauges["storage_events_gb", default: 0]))
                        .monospacedDigit()
                }

                Divider()

                // Totals
                HStack {
                    Text("Total Shadow:")
                        .fontWeight(.medium)
                    Spacer()
                    Text(formatGB(snapshot.gauges["storage_total_gb", default: 0]))
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
                HStack {
                    Text("Disk available:")
                    Spacer()
                    Text(formatGB(snapshot.gauges["storage_disk_available_gb", default: 0]))
                        .monospacedDigit()
                }

                Divider()

                // Retention activity
                HStack {
                    Text("Retention sweeps:")
                    Spacer()
                    Text("\(snapshot.counters["retention_sweeps_total", default: 0])")
                        .monospacedDigit()
                }
                HStack {
                    Text("Keyframes extracted:")
                    Spacer()
                    Text("\(snapshot.counters["retention_keyframes_extracted_total", default: 0])")
                        .monospacedDigit()
                }
                HStack {
                    Text("Keyframes deleted:")
                    Spacer()
                    Text("\(snapshot.counters["retention_keyframes_deleted_total", default: 0])")
                        .monospacedDigit()
                }
                HStack {
                    Text("Segments deleted:")
                    Spacer()
                    Text("\(snapshot.counters["retention_segments_deleted_total", default: 0])")
                        .monospacedDigit()
                }
            }
        }
    }

    private func formatGB(_ gb: Double) -> String {
        if gb < 0.01 {
            let mb = gb * 1024
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.2f GB", gb)
    }

    // MARK: - Warnings

    private var warningsSection: some View {
        GroupBox("Recent Warnings") {
            if snapshot.warnings.isEmpty {
                Text("No warnings")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(snapshot.warnings.prefix(20)) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(warningColor(warning.severity))
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(warning.code)
                                    .font(.caption.monospaced().bold())
                                Text(warning.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(warning.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    // MARK: - Intelligence (LLM / Summary)

    @State private var llmModeSelection: String = UserDefaults.standard.string(forKey: "llmMode") ?? "auto"
    @State private var cloudConsent: Bool = UserDefaults.standard.bool(forKey: "llmCloudConsentGranted")
    @State private var cloudModelId: String = UserDefaults.standard.string(forKey: "llmCloudModelId") ?? "claude-sonnet-4-6"
    @State private var apiKeyDisplay: String = {
        if let data = KeychainHelper.load(service: "com.shadow.app.llm", account: "anthropic-api-key"),
           let key = String(data: data, encoding: .utf8), key.count > 4 {
            return "***\(key.suffix(4))"
        }
        return "Not set"
    }()
    @State private var summarizeStatus: String = ""
    @State private var isSummarizing: Bool = false
    @State private var overlayEnabled: Bool = UserDefaults.standard.object(forKey: ProactiveDeliveryManager.overlayEnabledKey) as? Bool ?? true
    @State private var pushEnabled: Bool = UserDefaults.standard.object(forKey: ProactiveDeliveryManager.pushEnabledKey) as? Bool ?? true
    @State private var ollamaEnabled: Bool = UserDefaults.standard.bool(forKey: "ollamaEnabled")
    @State private var ollamaModelId: String = UserDefaults.standard.string(forKey: "ollamaModelId") ?? "qwen2.5:7b-instruct"

    private var intelligenceSection: some View {
        GroupBox("Intelligence") {
            VStack(alignment: .leading, spacing: 6) {
                // Active provider
                metricRow("Active provider", value: snapshot.stringGauges["llm_active_provider"] ?? "none")
                metricRow("Active model", value: snapshot.stringGauges["llm_active_model_id"] ?? "none")
                metricRow("Mode", value: snapshot.stringGauges["llm_mode"] ?? "auto")
                metricRow("Local model loaded", value: snapshot.gauges["llm_local_fast_model_loaded", default: 0] > 0 ? "Yes" : "No")

                // Provisioning status
                provisioningStatusRow

                Divider()

                // Mode picker
                HStack {
                    Text("Provider mode:").foregroundStyle(.secondary)
                    Picker("", selection: $llmModeSelection) {
                        Text("Auto").tag("auto")
                        Text("Local Only").tag("localOnly")
                        Text("Cloud Only").tag("cloudOnly")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: llmModeSelection) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "llmMode")
                        if let mode = LLMMode(rawValue: newValue),
                           let orchestrator = currentLLMOrchestrator() {
                            Task { await orchestrator.setMode(mode) }
                        }
                    }
                }
                .font(.callout)

                // Cloud consent toggle
                Toggle(isOn: $cloudConsent) {
                    VStack(alignment: .leading) {
                        Text("Enable cloud LLM")
                        Text("When enabled, transcript text may be sent to Anthropic's API for summarization. Data is not stored by Anthropic.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: cloudConsent) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "llmCloudConsentGranted")
                }

                // Cloud settings (only visible when consent granted)
                if cloudConsent {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Cloud model:").foregroundStyle(.secondary)
                            TextField("Model ID", text: $cloudModelId)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    UserDefaults.standard.set(cloudModelId, forKey: "llmCloudModelId")
                                }
                        }
                        Text("Press Return to save")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.callout)

                    HStack {
                        Text("API key:").foregroundStyle(.secondary)
                        Text(apiKeyDisplay)
                            .font(.callout.monospaced())
                        Spacer()
                        Button("Set") {
                            // Simple paste-from-clipboard flow
                            if let key = NSPasteboard.general.string(forType: .string), !key.isEmpty {
                                let data = Data(key.utf8)
                                if KeychainHelper.save(service: "com.shadow.app.llm", account: "anthropic-api-key", data: data) {
                                    apiKeyDisplay = "***\(key.suffix(4))"
                                }
                            }
                        }
                        .help("Paste API key from clipboard")
                        Button("Remove") {
                            KeychainHelper.delete(service: "com.shadow.app.llm", account: "anthropic-api-key")
                            apiKeyDisplay = "Not set"
                        }
                    }
                    .font(.callout)
                }

                Divider()

                // Ollama settings (opt-in)
                Toggle(isOn: $ollamaEnabled) {
                    VStack(alignment: .leading) {
                        Text("Enable Ollama")
                        Text("Connect to a locally-running Ollama instance for custom model support.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: ollamaEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "ollamaEnabled")
                    if let orchestrator = currentLLMOrchestrator() {
                        Task {
                            if newValue {
                                let provider = OllamaProvider()
                                await orchestrator.insertProvider(provider, at: 2)
                            } else {
                                await orchestrator.removeProvider(named: "ollama_local")
                            }
                        }
                    }
                }

                if ollamaEnabled {
                    HStack {
                        Text("Status:").foregroundStyle(.secondary)
                        let available = snapshot.gauges["ollama_available", default: 0] > 0
                        Circle()
                            .fill(available ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(available ? "Connected" : "Not detected")
                            .foregroundStyle(available ? .primary : .secondary)
                    }
                    .font(.callout)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Ollama model:").foregroundStyle(.secondary)
                            TextField("Model name", text: $ollamaModelId)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    UserDefaults.standard.set(ollamaModelId, forKey: "ollamaModelId")
                                }
                        }
                        Text("Press Return to save (e.g. qwen2.5:7b-instruct, llama3.1:8b)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.callout)

                    metricRow("Ollama attempts", value: "\(snapshot.counters["ollama_attempt_total", default: 0])")
                    metricRow("Ollama successes", value: "\(snapshot.counters["ollama_success_total", default: 0])")
                    metricRow("Ollama failures", value: "\(snapshot.counters["ollama_fail_total", default: 0])")

                    if snapshot.latencyP50["ollama_latency_ms"] != nil {
                        metricRow("Ollama latency (p50)", value: String(format: "%.0f ms", snapshot.latencyP50["ollama_latency_ms", default: 0]))
                    }
                }

                Divider()

                // Summarize trigger
                HStack {
                    Button {
                        guard !isSummarizing else { return }
                        isSummarizing = true
                        summarizeStatus = "Resolving meeting..."
                        Task {
                            defer { isSummarizing = false }
                            guard let queue = currentSummaryJobQueue() else {
                                summarizeStatus = "Error: queue not initialized"
                                return
                            }
                            do {
                                let result = try await SummaryCoordinator.summarizeLatestMeeting(queue: queue)
                                switch result {
                                case .success(let summary):
                                    summarizeStatus = "Done: \(summary.title)"
                                case .noMeetingFound:
                                    summarizeStatus = "No meeting found"
                                case .disambiguation(let candidates):
                                    summarizeStatus = "Ambiguous: \(candidates.count) candidates"
                                }
                            } catch {
                                summarizeStatus = "Error: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Text("Summarize Last Meeting")
                    }
                    .disabled(isSummarizing)

                    if isSummarizing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
                .font(.callout)

                if !summarizeStatus.isEmpty {
                    Text(summarizeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                // Summary metrics
                metricRow("Summaries requested", value: "\(snapshot.counters["summary_request_total", default: 0])")
                metricRow("Summaries succeeded", value: "\(snapshot.counters["summary_success_total", default: 0])")
                metricRow("Summaries failed", value: "\(snapshot.counters["summary_fail_total", default: 0])")
                metricRow("Local attempts", value: "\(snapshot.counters["summary_local_attempt_total", default: 0])")
                metricRow("Cloud attempts", value: "\(snapshot.counters["summary_cloud_attempt_total", default: 0])")
                metricRow("Cloud blocked (no consent)", value: "\(snapshot.counters["summary_cloud_blocked_no_consent_total", default: 0])")
                metricRow("Schema invalid", value: "\(snapshot.counters["summary_schema_invalid_total", default: 0])")
                metricRow("Jobs coalesced", value: "\(snapshot.counters["summary_job_coalesced_total", default: 0])")

                if snapshot.latencyP50["summary_total_ms"] != nil {
                    metricRow("Latency (p50)", value: String(format: "%.0f ms", snapshot.latencyP50["summary_total_ms", default: 0]))
                    metricRow("Latency (p95)", value: String(format: "%.0f ms", snapshot.latencyP95["summary_total_ms", default: 0]))
                }
            }
        }
    }

    // MARK: - Proactive Engine

    private var proactiveSection: some View {
        GroupBox("Proactive Engine") {
            VStack(alignment: .leading, spacing: 6) {
                metricRow("Candidates generated", value: "\(snapshot.counters["proactive_candidate_total", default: 0])")
                metricRow("Pushed (overlay)", value: "\(snapshot.counters["proactive_push_total", default: 0])")
                metricRow("Inbox only", value: "\(snapshot.counters["proactive_inbox_only_total", default: 0])")
                metricRow("Dropped", value: "\(snapshot.counters["proactive_drop_total", default: 0])")

                Divider()

                metricRow("Feedback: thumbs up", value: "\(snapshot.counters["proactive_feedback_thumbs_up_total", default: 0])")
                metricRow("Feedback: thumbs down", value: "\(snapshot.counters["proactive_feedback_thumbs_down_total", default: 0])")
                metricRow("Feedback: dismiss", value: "\(snapshot.counters["proactive_feedback_dismiss_total", default: 0])")
                metricRow("Feedback: snooze", value: "\(snapshot.counters["proactive_feedback_snooze_total", default: 0])")

                Divider()

                metricRow("Tuner updates", value: "\(snapshot.counters["proactive_tuner_update_total", default: 0])")
                metricRow("Tuner fallbacks", value: "\(snapshot.counters["proactive_tuner_fallback_total", default: 0])")

                Divider()

                // Overlay delivery metrics
                metricRow("Overlay shown", value: "\(snapshot.counters["proactive_overlay_shown_total", default: 0])")
                metricRow("Overlay dismissed", value: "\(snapshot.counters["proactive_overlay_dismissed_total", default: 0])")
                metricRow("Overlay auto-dismissed", value: "\(snapshot.counters["proactive_overlay_autodismiss_total", default: 0])")
                metricRow("Overlay clicked", value: "\(snapshot.counters["proactive_overlay_clicked_total", default: 0])")
                metricRow("Inbox items created", value: "\(snapshot.counters["proactive_inbox_created_total", default: 0])")

                Divider()

                // Analyzer metrics
                metricRow("Analyzer runs", value: "\(snapshot.counters["proactive_analyze_runs_total", default: 0])")
                metricRow("Analyzer failures", value: "\(snapshot.counters["proactive_analyze_fail_total", default: 0])")

                Divider()

                // Delivery controls
                Toggle("Overlay nudges", isOn: $overlayEnabled)
                    .font(.callout)
                    .onChange(of: overlayEnabled) { _, val in
                        UserDefaults.standard.set(val, forKey: ProactiveDeliveryManager.overlayEnabledKey)
                    }
                Toggle("Push suggestions", isOn: $pushEnabled)
                    .font(.callout)
                    .onChange(of: pushEnabled) { _, val in
                        UserDefaults.standard.set(val, forKey: ProactiveDeliveryManager.pushEnabledKey)
                    }

                Divider()

                // Context engine metrics
                metricRow("Heartbeat runs", value: "\(snapshot.counters["context_heartbeat_run_total", default: 0])")
                metricRow("Heartbeat skips", value: "\(snapshot.counters["context_heartbeat_skip_total", default: 0])")
                metricRow("Heartbeat failures", value: "\(snapshot.counters["context_heartbeat_fail_total", default: 0])")
                metricRow("Backoff active", value: snapshot.gauges["context_backoff_active", default: 0] > 0 ? "Yes" : "No")
                metricRow("Episodes generated", value: "\(snapshot.counters["context_episode_generated_total", default: 0])")
                metricRow("Daily records", value: "\(snapshot.counters["context_day_generated_total", default: 0])")
                metricRow("Weekly records", value: "\(snapshot.counters["context_week_generated_total", default: 0])")

                if snapshot.latencyP50["context_synthesis_ms"] != nil {
                    metricRow("Synthesis latency (p50)", value: String(format: "%.0f ms", snapshot.latencyP50["context_synthesis_ms", default: 0]))
                    metricRow("Synthesis latency (p95)", value: String(format: "%.0f ms", snapshot.latencyP95["context_synthesis_ms", default: 0]))
                }

                // Context packer metrics
                metricRow("Context packs", value: "\(snapshot.counters["context_pack_total", default: 0])")
                metricRow("Pack truncations", value: "\(snapshot.counters["context_pack_truncation_total", default: 0])")
                if snapshot.gauges["context_pack_estimated_tokens"] != nil {
                    metricRow("Pack tokens (last)", value: String(format: "%.0f", snapshot.gauges["context_pack_estimated_tokens", default: 0]))
                }
                if snapshot.latencyP50["context_pack_ms"] != nil {
                    metricRow("Pack latency (p50)", value: String(format: "%.1f ms", snapshot.latencyP50["context_pack_ms", default: 0]))
                }

                Divider()

                HStack {
                    Button {
                        showProactiveInbox()
                    } label: {
                        Label("Open Inbox", systemImage: "tray.fill")
                    }
                    Button {
                        showProactiveActivity()
                    } label: {
                        Label("Open Activity", systemImage: "brain.head.profile")
                    }
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Provisioning Status

    private var provisioningStatusRow: some View {
        let downloading = snapshot.gauges["provisioning_download_active", default: 0] > 0
        let fastPlanned = snapshot.gauges["provisioning_plan_fast", default: 0] > 0
        let deepPlanned = snapshot.gauges["provisioning_plan_deep", default: 0] > 0
        let completed = snapshot.counters["provisioning_download_complete_total", default: 0]

        return VStack(alignment: .leading, spacing: 4) {
            if downloading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading local AI model...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if fastPlanned || deepPlanned {
                let fastDownloaded = LocalModelRegistry.isDownloaded(LocalModelRegistry.fastDefault)
                let deepDownloaded = LocalModelRegistry.isDownloaded(LocalModelRegistry.deepDefault)

                if fastPlanned && !fastDownloaded {
                    metricRow("Fast model (7B)", value: "Not downloaded")
                } else if fastPlanned && fastDownloaded {
                    metricRow("Fast model (7B)", value: "Ready")
                }

                if deepPlanned && !deepDownloaded {
                    metricRow("Deep model (32B)", value: "Not downloaded")
                } else if deepPlanned && deepDownloaded {
                    metricRow("Deep model (32B)", value: "Ready")
                }
            }

            if completed > 0 {
                metricRow("Models provisioned", value: "\(completed)")
            }
        }
    }

    private var actionsSection: some View {
        GroupBox("Actions") {
            HStack {
                Button("Export Bundle") {
                    DiagnosticsExporter.export()
                }
                Button("Reset Counters") {
                    DiagnosticsStore.shared.resetCounters()
                    snapshot = DiagnosticsStore.shared.snapshot()
                }
            }
        }
    }

    // MARK: - Helpers

    private func metricRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
    }

    private var healthColor: Color {
        let drops = snapshot.counters["ingest_events_dropped_total", default: 0]
        let fails = snapshot.counters["ingest_batch_write_fail_total", default: 0]
        if fails > 0 { return .red }
        if drops > 0 { return .yellow }
        return .green
    }

    private var healthLabel: String {
        let drops = snapshot.counters["ingest_events_dropped_total", default: 0]
        let fails = snapshot.counters["ingest_batch_write_fail_total", default: 0]
        if fails > 0 { return "Degraded" }
        if drops > 0 { return "Warnings" }
        return "Healthy"
    }

    private func warningColor(_ severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .error: return .orange
        case .warning: return .yellow
        }
    }
}
