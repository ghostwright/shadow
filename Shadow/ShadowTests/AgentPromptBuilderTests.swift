import XCTest
@testable import Shadow

final class AgentPromptBuilderTests: XCTestCase {

    /// Fixed date for deterministic tests: 2026-02-22 12:00:00 UTC (noon — avoids day-boundary issues)
    private let fixedDate = Date(timeIntervalSince1970: 1_771_761_600)
    private let gmtZone = TimeZone(secondsFromGMT: 0)!
    private let plusFiveThirty = TimeZone(secondsFromGMT: 5 * 3600 + 1800)!

    // 1. Prompt includes timezone identifier
    func testPromptIncludesTimezone() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        let context = AgentPromptBuilder.formatDateContext(fixedDate)
        XCTAssertTrue(prompt.contains("Timezone: \(context.timezoneId)"),
                       "Prompt should include timezone identifier")
    }

    // 2. Prompt includes ISO-8601 timestamp
    func testPromptIncludesISO8601() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("ISO-8601:"), "Prompt should include ISO-8601 label")
        XCTAssertTrue(prompt.contains("2026"), "Prompt should include the year from the date")
    }

    // 3. Prompt includes current time context line
    func testPromptIncludesCurrentTimeLine() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("Current time:"),
                       "Prompt should include 'Current time:' context line")
    }

    // 4. Core rules are preserved
    func testCoreRulesPreserved() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("You are Shadow, an AI assistant"))
        XCTAssertTrue(prompt.contains("cite evidence with timestamps"))
        XCTAssertTrue(prompt.contains("Never fabricate data"))
        XCTAssertTrue(prompt.contains("Keep answers concise"))
        XCTAssertTrue(prompt.contains("displayId"))
    }

    // 5. Mentions relative time conversion and Unix timestamp anchor
    func testMentionsRelativeTimeConversion() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("Current Unix microseconds:"),
                       "Prompt should include Unix timestamp anchor")
        XCTAssertTrue(prompt.contains("startUs < endUs"),
                       "Prompt should remind about correct timestamp ordering")
    }

    // 6. Prompt mentions Unix microseconds for tool timestamp context
    func testPromptMentionsUnixMicroseconds() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("Unix microseconds"),
                       "Prompt should explain tool timestamp format")
    }

    // 7. DateContext formatting with explicit GMT timezone
    func testDateContextFormatting_GMT() {
        let context = AgentPromptBuilder.formatDateContext(fixedDate, timeZone: gmtZone)

        XCTAssertEqual(context.timezoneId, "GMT")
        XCTAssertEqual(context.utcOffset, "+0")
        XCTAssertTrue(context.localDateTime.contains("February 22, 2026"))
        XCTAssertTrue(context.localDateTime.contains("12:00 PM"),
                       "Noon UTC should be 12:00 PM, got \(context.localDateTime)")
        XCTAssertTrue(context.iso8601.contains("2026-02-22T12:00:00"))
    }

    // 8. DateContext formatting with +5:30 offset timezone
    func testDateContextFormatting_PlusFiveThirty() {
        let context = AgentPromptBuilder.formatDateContext(fixedDate, timeZone: plusFiveThirty)

        XCTAssertEqual(context.utcOffset, "+5:30")
        XCTAssertTrue(context.localDateTime.contains("5:30 PM"),
                       "12:00 UTC + 5:30 should be 5:30 PM, got \(context.localDateTime)")
        XCTAssertTrue(context.localDateTime.contains("February 22, 2026"))
    }

    // 9. systemPrompt computed property returns non-empty string with current context
    func testSystemPromptComputedProperty() {
        let prompt = AgentPromptBuilder.systemPrompt
        XCTAssertFalse(prompt.isEmpty)
        XCTAssertTrue(prompt.contains("Current time:"))
        XCTAssertTrue(prompt.contains("Timezone:"))
        XCTAssertTrue(prompt.contains("ISO-8601:"))
    }

    // 10. Visual tool instructions present
    func testVisualToolInstructions() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("search_visual_memories"))
        XCTAssertTrue(prompt.contains("inspect_screenshots"))
        XCTAssertTrue(prompt.contains("visual"))
    }

    // 11. Tool descriptions section exists
    func testToolDescriptionsSection() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("# Tools"))
        XCTAssertTrue(prompt.contains("search_hybrid"))
        XCTAssertTrue(prompt.contains("get_transcript_window"))
        XCTAssertTrue(prompt.contains("resolve_latest_meeting"))
        XCTAssertTrue(prompt.contains("get_day_summary"))
        XCTAssertTrue(prompt.contains("search_summaries"))
        // New tools
        XCTAssertTrue(prompt.contains("ax_wait"))
        XCTAssertTrue(prompt.contains("ax_focus_app"))
        XCTAssertTrue(prompt.contains("ax_read_text"))
    }

    // 12. Audio source guide present
    func testAudioSourceGuide() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("Audio Source"))
        XCTAssertTrue(prompt.contains("\"mic\""), "Prompt should explain mic = user's voice")
        XCTAssertTrue(prompt.contains("\"system\""), "Prompt should explain system = others")
    }

    // 13. Meeting strategy — transcript-first
    func testMeetingStrategy() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("For any meeting question"))
        XCTAssertTrue(prompt.contains("get_transcript_window"))
        XCTAssertTrue(prompt.contains("raw transcript"))
    }

    // 14. Unix microsecond anchor is correct for the fixed date
    func testUnixMicrosecondAnchor() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        let expectedUs = UInt64(fixedDate.timeIntervalSince1970 * 1_000_000)
        XCTAssertTrue(prompt.contains("\(expectedUs)"),
                       "Prompt should contain the exact Unix µs for the injected date")
    }

    // 15. Screenshot tool guidance includes arg shape and current screen example
    func testScreenshotCurrentScreenGuidance() {
        let prompt = AgentPromptBuilder.buildSystemPrompt(now: fixedDate)
        XCTAssertTrue(prompt.contains("timestampUs"),
                       "Prompt should show the required timestampUs arg for inspect_screenshots")
        XCTAssertTrue(prompt.contains("displayId"),
                       "Prompt should show the required displayId arg for inspect_screenshots")
        XCTAssertTrue(prompt.contains("screen"),
                       "Prompt should mention screen use case")
    }
}
