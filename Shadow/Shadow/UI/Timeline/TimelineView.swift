import SwiftUI

// MARK: - Audio Track Anchor Preference

/// Anchor preference key for audio track bounds, keyed by source ("mic" / "system").
/// Resolved via `geo[anchor]` inside overlayPreferenceValue so the frames
/// are always in the same coordinate space as the PlayheadView gesture.
private struct AudioTrackAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Main timeline view: screenshot display + app track + input density + time axis.
/// Uses a fixed-height track section so the screenshot fills remaining space.
struct TimelineView: View {
    @State private var viewModel = TimelineViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Day navigation + optional display picker
            DayNavigator(
                dateString: viewModel.displayDate,
                onPrevious: { viewModel.previousDay() },
                onNext: { viewModel.nextDay() },
                canGoNext: viewModel.canGoNext,
                displayIDs: viewModel.availableDisplayIDs,
                selectedDisplayID: viewModel.selectedDisplayID,
                onSelectDisplay: { viewModel.selectDisplay($0) }
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            // Screenshot panel — fills remaining vertical space
            ScreenshotView(
                image: viewModel.currentFrame,
                appName: viewModel.currentAppName,
                windowTitle: viewModel.currentWindowTitle,
                timestamp: viewModel.playheadDate
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .opacity(0.5)
                .padding(.horizontal, 20)

            // Timeline track section — fixed height at bottom
            timelineSection
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(.background)
        .onAppear {
            let consumedJump = viewModel.startObserving()
            if !consumedJump {
                viewModel.loadDay()
            }
        }
        .onDisappear {
            viewModel.stopObserving()
        }
    }

    // MARK: - Timeline Tracks

    private var timelineSection: some View {
        // VStack with fixed-height children — overlay constrains PlayheadView
        // to this exact size, preventing GeometryReader expansion.
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 12)

            // "Apps" label
            Text("Apps")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.bottom, 3)

            // App usage track
            AppTrackView(
                entries: viewModel.appEntries,
                dayStart: viewModel.visibleStartUs,
                dayEnd: viewModel.visibleEndUs
            )
            .frame(height: 48)

            Spacer().frame(height: 10)

            // "Input" label
            Text("Input")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.bottom, 3)

            // Input density track
            InputDensityView(
                entries: viewModel.inputEntries,
                dayStart: viewModel.visibleStartUs,
                dayEnd: viewModel.visibleEndUs
            )
            .frame(height: 24)

            // Audio rows — separate Mic and System lanes
            if !viewModel.audioSegments.isEmpty {
                Spacer().frame(height: 10)

                Text("Audio")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 3)

                if !viewModel.micSegments.isEmpty {
                    AudioTrackView(
                        segments: viewModel.micSegments,
                        dayStart: viewModel.visibleStartUs,
                        dayEnd: viewModel.visibleEndUs
                    )
                    .frame(height: 24)
                    .anchorPreference(key: AudioTrackAnchorKey.self, value: .bounds) { ["mic": $0] }
                }

                if !viewModel.systemSegments.isEmpty {
                    if !viewModel.micSegments.isEmpty {
                        Spacer().frame(height: 4)
                    }

                    AudioTrackView(
                        segments: viewModel.systemSegments,
                        dayStart: viewModel.visibleStartUs,
                        dayEnd: viewModel.visibleEndUs
                    )
                    .frame(height: 24)
                    .anchorPreference(key: AudioTrackAnchorKey.self, value: .bounds) { ["system": $0] }
                }
            }

            Spacer().frame(height: 12)

            // Time axis
            TimeAxisView(
                dayStart: viewModel.visibleStartUs,
                dayEnd: viewModel.visibleEndUs
            )
            .frame(height: 24)

            Spacer().frame(height: 16)
        }
        .overlayPreferenceValue(AudioTrackAnchorKey.self) { anchors in
            // GeometryReader resolves anchors in the overlay's own coordinate
            // space — the same space where PlayheadView's gesture lives.
            GeometryReader { geo in
                let resolvedFrames = anchors.mapValues { geo[$0] }
                PlayheadView(
                    position: $viewModel.playheadPosition,
                    onScrub: { position in
                        viewModel.scrubTo(position: position)
                    },
                    onTap: { location, _ in
                        handleTimelineTap(at: location, trackFrames: resolvedFrames)
                    }
                )
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Tap Routing

    /// Vertical tolerance (points) added above/below each audio track frame for hit-testing.
    /// Each row is only 24pt tall — a small tolerance makes edge taps reliable.
    private static let audioTrackVerticalTolerance: CGFloat = 4

    /// Route a tap to the correct audio track row. Checks each source's resolved
    /// frame (from anchor preferences) independently. If the tap falls inside a
    /// row's frame (with vertical tolerance), hit-test against that row's segments.
    ///
    /// Both `location` and frame values are in the overlay's coordinate space
    /// (resolved via anchor preference), so the comparison is always valid.
    private func handleTimelineTap(at location: CGPoint, trackFrames: [String: CGRect]) {
        DiagnosticsStore.shared.increment("audio_timeline_tap_total")

        guard !viewModel.audioSegments.isEmpty else { return }

        // Try each audio source row
        for (source, frame) in trackFrames {
            guard frame.size.width > 0 else { continue }

            let expandedFrame = frame.insetBy(
                dx: 0,
                dy: -Self.audioTrackVerticalTolerance
            )

            guard expandedFrame.contains(location) else { continue }

            DiagnosticsStore.shared.increment("audio_timeline_tap_in_track_total")
            DiagnosticsStore.shared.increment("audio_timeline_tap_in_\(source)_total")

            let segments = source == "mic" ? viewModel.micSegments : viewModel.systemSegments
            let localX = location.x - frame.origin.x
            let trackWidth = frame.size.width

            let audioTrack = AudioTrackView(
                segments: segments,
                dayStart: viewModel.visibleStartUs,
                dayEnd: viewModel.visibleEndUs
            )

            guard let hit = audioTrack.segmentAt(tapX: localX, viewWidth: trackWidth) else {
                DiagnosticsStore.shared.increment("audio_timeline_tap_miss_segment_total")
                return
            }

            DiagnosticsStore.shared.increment("audio_timeline_tap_hit_segment_total")
            DiagnosticsStore.shared.increment("audio_timeline_play_start_total")
            AudioPlayer.shared.playSegment(hit.segment, seekSeconds: hit.seekSeconds)
            return
        }
    }
}
