import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "StreamingText")

/// A view that reveals text character by character, simulating AI speech.
///
/// Text is organized into groups, where each group is an array of lines.
/// Characters appear at a steady cadence (`characterDelay`), with a longer
/// pause (`groupPause`) inserted between groups. This creates the feeling
/// of a thoughtful speaker pausing between ideas.
///
/// The parent controls fast-forward by setting `revealAll` to true. Completion
/// is reported via the `onComplete` callback.
///
/// Usage:
/// ```swift
/// @State private var textRevealed = false
///
/// StreamingTextView(
///     groups: [
///         ["Your computer sees everything you do.",
///          "But it forgets everything, instantly."],
///         ["Shadow remembers."],
///     ],
///     revealAll: $textRevealed,
///     onComplete: { print("done") }
/// )
/// ```
struct StreamingTextView: View {
    /// Array of text groups. Each group is an array of lines joined by newlines.
    /// Groups are separated by double newlines to create visual paragraph breaks.
    let groups: [[String]]

    /// Delay between each character reveal, in seconds. Default: 35ms.
    var characterDelay: TimeInterval = 0.035

    /// Pause duration between groups, in seconds. Default: 750ms.
    var groupPause: TimeInterval = 0.75

    /// Set to true from the parent to immediately reveal all text (fast-forward).
    @Binding var revealAll: Bool

    /// Called when all characters have been revealed (either by streaming or fast-forward).
    var onComplete: @MainActor () -> Void = {}

    /// The observable object driving the streaming timer.
    @State private var streamer: TextStreamer?

    /// The full text assembled from groups.
    private var fullText: String {
        groups.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    var body: some View {
        let count = streamer?.visibleCount ?? 0
        let text = String(fullText.prefix(count))
        OnboardingTheme.narrativeText(Text(text))
            .frame(maxWidth: .infinity)
            .onAppear {
                guard streamer == nil else { return }
                let s = TextStreamer(
                    fullText: fullText,
                    groupBoundaries: computeGroupBoundaries(),
                    characterDelay: characterDelay,
                    groupPause: groupPause,
                    onComplete: onComplete
                )
                streamer = s
                s.start()
            }
            .onDisappear {
                streamer?.stop()
            }
            .onChange(of: revealAll) { _, newValue in
                if newValue {
                    streamer?.revealAllText()
                }
            }
    }

    // MARK: - Text Computation

    /// Compute the character indices where a group boundary pause should occur.
    private func computeGroupBoundaries() -> Set<Int> {
        var indices = Set<Int>()
        let chars = Array(fullText)
        var i = 0
        while i < chars.count - 1 {
            if chars[i] == "\n" && i + 1 < chars.count && chars[i + 1] == "\n" {
                indices.insert(i)
                i += 2
            } else {
                i += 1
            }
        }
        return indices
    }
}

// MARK: - TextStreamer

/// Observable class that drives the character-by-character text reveal.
///
/// Timer callbacks need a stable reference to mutate state, so this must be
/// a class. @Observable makes SwiftUI re-render when `visibleCount` changes.
@Observable
@MainActor
final class TextStreamer {
    /// Number of characters currently visible.
    private(set) var visibleCount: Int = 0

    /// Whether all characters have been revealed.
    private(set) var isComplete: Bool = false

    private let fullText: String
    private let groupBoundaries: Set<Int>
    private let characterDelay: TimeInterval
    private let groupPause: TimeInterval
    private let onComplete: @MainActor () -> Void
    private var timer: Timer?

    init(
        fullText: String,
        groupBoundaries: Set<Int>,
        characterDelay: TimeInterval,
        groupPause: TimeInterval,
        onComplete: @escaping @MainActor () -> Void
    ) {
        self.fullText = fullText
        self.groupBoundaries = groupBoundaries
        self.characterDelay = characterDelay
        self.groupPause = groupPause
        self.onComplete = onComplete
    }

    func start() {
        guard visibleCount == 0 else { return }
        logger.debug("Starting text stream: \(self.fullText.count) characters")
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func revealAllText() {
        stop()
        visibleCount = fullText.count
        if !isComplete {
            isComplete = true
            onComplete()
        }
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: characterDelay, repeats: true) { [weak self] _ in
            // Timer fires on main run loop. MainActor.assumeIsolated avoids
            // sending the non-Sendable Timer across isolation boundaries.
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func tick() {
        guard visibleCount < fullText.count else {
            timer?.invalidate()
            timer = nil
            if !isComplete {
                isComplete = true
                logger.debug("Text stream complete")
                onComplete()
            }
            return
        }

        visibleCount += 1

        // Check if we hit a group boundary and need to pause
        if groupBoundaries.contains(visibleCount - 1) && visibleCount < fullText.count {
            timer?.invalidate()
            timer = nil

            DispatchQueue.main.asyncAfter(deadline: .now() + groupPause) { [weak self] in
                MainActor.assumeIsolated {
                    self?.scheduleTimer()
                }
            }
        }
    }
}
