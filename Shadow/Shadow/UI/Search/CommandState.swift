import Foundation

/// State machine for command execution lifecycle within the search overlay.
/// Drives content switching, panel height, and Esc behavior.
enum CommandState {
    /// Normal search mode (default).
    case idle
    /// Command is executing. Carries a user-visible stage description.
    case running(stage: String)
    /// Command completed successfully with a meeting summary.
    case result(MeetingSummary)
    /// Command completed with an error.
    case error(CommandError)
    /// Agent is running — state held in SearchViewModel.agentStreamState.
    case agentStreaming
    /// Agent completed — state held in SearchViewModel.agentStreamState.
    case agentResult

    /// Desired panel height for this state.
    var panelHeight: CGFloat {
        switch self {
        case .idle: 640
        case .running: 240
        case .result: 640
        case .error: 300
        case .agentStreaming: 560
        case .agentResult: 640
        }
    }

    /// Panel width (constant across all states).
    static let panelWidth: CGFloat = 740

    /// Whether this state represents a non-idle command flow.
    var isCommandActive: Bool {
        switch self {
        case .idle: false
        default: true
        }
    }
}

/// Error cases for the command state.
enum CommandError: Equatable {
    /// No recent meeting detected in the lookback window.
    case noMeetingFound
    /// Multiple candidate meetings found — disambiguation not yet supported.
    case multipleMeetingsFound
    /// SummaryJobQueue not yet initialized (LLM subsystem not ready).
    case queueNotReady
    /// Provider or pipeline error with detail message.
    case providerError(String)
    /// Agent runtime error with user-facing detail.
    case agentError(String)

    var title: String {
        switch self {
        case .noMeetingFound: "No Recent Meeting Found"
        case .multipleMeetingsFound: "Multiple Meetings Detected"
        case .queueNotReady: "Summarization Unavailable"
        case .providerError: "Summarization Failed"
        case .agentError: "Agent Failed"
        }
    }

    var message: String {
        switch self {
        case .noMeetingFound:
            "Shadow looks for video call windows (Zoom, Teams, Meet) with active transcription in the last 24 hours."
        case .multipleMeetingsFound:
            "Shadow found multiple recent meetings. Disambiguation is not yet supported."
        case .queueNotReady:
            "The LLM provider is not configured. Check Diagnostics for details."
        case .providerError(let detail):
            detail
        case .agentError(let detail):
            detail
        }
    }

    var iconName: String {
        switch self {
        case .noMeetingFound: "calendar.badge.exclamationmark"
        case .multipleMeetingsFound: "person.2.circle"
        case .queueNotReady: "cpu"
        case .providerError: "exclamationmark.triangle"
        case .agentError: "exclamationmark.triangle"
        }
    }
}
