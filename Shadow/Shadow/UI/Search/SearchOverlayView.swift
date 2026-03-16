import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SearchOverlay")

/// Main search overlay view. Shows a search field at top with state-dependent content below.
///
/// States:
/// - Idle: search results list (existing behavior)
/// - Running: animated progress view with stage text
/// - Result: rich meeting summary with evidence deep-links
/// - Error: icon + message + suggestion
///
/// Keyboard:
/// - ↑/↓: navigate search results
/// - ↩: open selected search result
/// - ⌘↩: run meeting summarization command
/// - Space: play/pause transcript audio (search mode only)
/// - Esc: state-dependent (cancel command → dismiss result → stop audio → dismiss panel)
struct SearchOverlayView: View {
    @Bindable var viewModel: SearchViewModel
    @FocusState private var isQueryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)

            // Content area switches on command state
            switch viewModel.commandState {
            case .idle:
                resultsList
            case .running(let stage):
                CommandProgressView(stage: stage)
            case .result(let summary):
                CommandResponseView(
                    summary: summary,
                    onOpenTimeline: viewModel.onOpenTimeline
                )
            case .error(let error):
                commandErrorView(error)
            case .agentStreaming:
                if let state = viewModel.agentStreamState {
                    AgentStreamingView(
                        state: state,
                        isComplete: false,
                        onOpenTimeline: viewModel.onOpenTimeline
                    )
                }
            case .agentResult:
                if let state = viewModel.agentStreamState {
                    AgentStreamingView(
                        state: state,
                        isComplete: true,
                        onOpenTimeline: viewModel.onOpenTimeline
                    )
                }
            }

            // Action bar: shown when query is non-empty and command is not active
            if !viewModel.query.isEmpty && !viewModel.commandState.isCommandActive {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 0.5)
                actionBar
            }
        }
        .frame(minHeight: 100)
        .frame(width: 740)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onKeyPress(.upArrow) {
            viewModel.moveSelectionUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveSelectionDown()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { keyPress in
            if keyPress.modifiers.contains(.command) {
                viewModel.executeCommand()
                return .handled
            }
            viewModel.confirmSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            escHandler()
        }
        .onKeyPress(.space) {
            // Only control playback when not typing in the query field
            guard !isQueryFieldFocused else { return .ignored }
            // Space only works in idle state (search mode)
            guard !viewModel.commandState.isCommandActive else { return .ignored }
            guard let selected = viewModel.selectedResult,
                  selected.sourceKind == "transcript" else {
                return .ignored
            }
            let player = AudioPlayer.shared
            if player.isPlaying || player.isPaused {
                player.togglePlayPause()
            } else {
                player.playTranscriptResult(selected)
            }
            return .handled
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)

            TextField("Search anything you've seen, heard, or done...", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($isQueryFieldFocused)
                .onSubmit {
                    viewModel.confirmSelection()
                }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Text(viewModel.agentRunFunction != nil ? "Ask Shadow" : "Summarize Last Meeting")
                    .font(.caption)
                    .foregroundStyle(SearchTheme.accent)
                Text("\u{2318}\u{21A9}")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SearchTheme.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(SearchTheme.accent)
            }
        }
        .padding(.horizontal, SearchTheme.contentPadding)
        .padding(.vertical, 8)
    }

    // MARK: - Results List

    @ViewBuilder
    private var resultsList: some View {
        if viewModel.results.isEmpty && !viewModel.query.isEmpty && !viewModel.isSearching {
            noResults
        } else if viewModel.results.isEmpty && viewModel.query.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(viewModel.results.enumerated()), id: \.offset) { index, result in
                            SearchResultCard(
                                result: result,
                                isSelected: index == viewModel.selectedIndex
                            )
                            .id(index)
                            .onTapGesture {
                                viewModel.selectedIndex = index
                                viewModel.openInTimeline(result)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: viewModel.selectedIndex) { _, newIndex in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Command Error View

    private func commandErrorView(_ error: CommandError) -> some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: error.iconName)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text(error.title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(error.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("Esc to return")
                .font(.caption)
                .foregroundStyle(.quaternary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Esc Handler

    private func escHandler() -> KeyPress.Result {
        switch viewModel.commandState {
        case .running, .agentStreaming:
            viewModel.cancelCommand()
            return .handled

        case .result, .error, .agentResult:
            viewModel.dismissCommandResult()
            return .handled

        case .idle:
            // Existing two-phase: first stop audio, then dismiss
            if AudioPlayer.shared.isPlaying || AudioPlayer.shared.isPaused {
                AudioPlayer.shared.stop()
                return .handled
            }
            viewModel.onDismiss?()
            return .handled
        }
    }

    // MARK: - Empty States

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("No memories found")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Try different words, or ask Shadow\nto search deeper with \u{2318}\u{21A9}")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 48)

            // Ghost mascot: neutral mood, breathing/blinking (96px for visual anchor)
            ExpressiveGhostView(mood: .constant(.neutral), size: 96)
                .frame(width: 96, height: 96)

            Spacer()
                .frame(height: 20)

            Text("What do you remember?")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.primary)

            Spacer()
                .frame(height: 6)

            Text("Type to search, or ask Shadow a question")
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer()
                .frame(minHeight: 32, maxHeight: 48)

            // Keyboard hints: two rows for breathing room
            VStack(spacing: 6) {
                HStack(spacing: 20) {
                    keyHint("arrows", "navigate")
                    keyHint("return", "open")
                    keyHint("\u{2318}\u{21A9}", "ask Shadow")
                }
                HStack(spacing: 20) {
                    keyHint("esc", "dismiss")
                }
            }

            Spacer()
                .frame(height: 32)
        }
        .frame(maxWidth: .infinity)
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4))
            Text(action)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
