# Privacy

Shadow records your screen, audio, keystrokes, and app activity. This is among the most sensitive data any application can collect. This document explains exactly what Shadow does with that data, what it does not do, and what control you have.

## The Core Principle

Shadow is local-first by design, not by policy. The architecture does not have a server component. There is no upload endpoint. There is no account system. There is no analytics SDK. The application binary does not contain code to transmit behavioral data to any external service.

This is verifiable. Shadow is open source. Read the capture pipeline, the storage engine, the network layer. There is no hidden telemetry.

## What Shadow Records

| Data | How | Stored Where |
|------|-----|-------------|
| Screen content | ScreenCaptureKit, 0.5 fps H.265 per display | `~/.shadow/data/media/video/` |
| Audio | AVFoundation mic + ScreenCaptureKit system audio | `~/.shadow/data/media/audio/` |
| Keystrokes | CGEventTap (passwords excluded at tap level) | `~/.shadow/data/events/` |
| Mouse/scroll/gestures | CGEventTap with AX element enrichment | `~/.shadow/data/events/` |
| Window titles and URLs | AXUIElement + NSWorkspace | `~/.shadow/data/events/` |
| Accessibility tree | Periodic AX snapshots of focused app | `~/.shadow/data/ax_snapshots/` |
| Clipboard | NSPasteboard observation | `~/.shadow/data/events/` |
| File changes | FSEvents on user directories | `~/.shadow/data/events/` |
| Git activity | FSEvents on .git directories | `~/.shadow/data/events/` |
| Terminal commands | AX tree reading of terminal buffer | `~/.shadow/data/events/` |
| Search queries | URL parsing + AX observation | `~/.shadow/data/events/` |
| Notifications | UNUserNotificationCenter + AX | `~/.shadow/data/events/` |
| Calendar | EventKit (read-only) | `~/.shadow/data/events/` |
| System context | Battery, WiFi, sleep/wake, displays | `~/.shadow/data/events/` |
| Audio transcripts | WhisperKit + Apple Speech (on-device) | `~/.shadow/data/indices/` |
| Visual embeddings | MobileCLIP-S2 (CoreML, on-device) | `~/.shadow/data/indices/vector/` |
| Episode summaries | On-device LLM (Qwen via MLX) | `~/.shadow/data/context/` |

## What Shadow Does NOT Do

- **Does not transmit behavioral data.** No screen recordings, keystrokes, audio, or activity data is ever sent to any server.
- **Does not require an account.** There is no sign-up, no login, no user identifier.
- **Does not collect analytics.** No usage metrics, no crash reports, no feature flags, no A/B testing.
- **Does not record passwords.** Secure text fields (password inputs, 2FA, credit card fields) are detected at the CGEventTap level and excluded before reaching storage.
- **Does not record during screen lock.** Capture pauses when your Mac is locked and resumes when unlocked.
- **Does not fingerprint your machine.** Shadow does not collect hardware identifiers, serial numbers, or advertising IDs.

## Cloud LLM (Opt-In Only)

Shadow can optionally use Claude (Anthropic) or GPT (OpenAI) for agent queries and meeting summaries. This is disabled by default. To enable it:

1. You must provide your own API key
2. You must explicitly grant consent through the onboarding flow or settings
3. A consent gate in the code prevents cloud requests without both conditions met

When cloud LLM is active, Shadow sends the text of your query and relevant context (episode summaries, recent activity text) to the provider. It does not send screenshots, raw audio, keystroke logs, or accessibility tree data to cloud providers.

When cloud LLM is disabled, all intelligence runs on-device via MLX (Qwen 7B/32B).

## User Controls

**Pause recording.** Click the pause button in the menu bar. All capture stops immediately. Resume when ready.

**Delete data.** All data is in `~/.shadow/data/`. Delete any subdirectory, any date folder, or the entire directory. Shadow will recreate empty directories on next launch.

**Complete removal.** To remove all Shadow data from your Mac:
```bash
rm -rf ~/.shadow/
```

**Retention.** Shadow manages storage automatically through three tiers:
- Hot (7 days): full video, audio, and all event data
- Warm (8-30 days): video deleted, keyframes retained, transcripts kept
- Cold (31+ days): only search indices and episode summaries retained

The retention policy runs automatically. Storage stays under a configurable cap. Transcripts are never deleted until their source audio has been fully transcribed.

## Permissions

Shadow requests five macOS permissions. Each is granted once through System Settings.

| Permission | Why | What Happens If Denied |
|------------|-----|----------------------|
| Screen Recording | Capture screen content | Screen capture disabled, everything else works |
| Accessibility | Read UI element tree, window titles, URLs | Window tracking and AX snapshots disabled |
| Input Monitoring | Record keystrokes, mouse, scroll | Input capture disabled |
| Microphone | Capture meeting audio | Audio recording disabled |
| Speech Recognition | On-device transcription | Transcription disabled, audio still captured |

Each permission can be revoked at any time in System Settings. Shadow degrades gracefully: disabling one permission disables that capture track without affecting the others.

## Open Source

Shadow is MIT licensed. Every line of the capture pipeline, storage engine, intelligence layer, and UI is in this repository. You do not need to trust a privacy policy written by a company. You can audit the code, build it yourself, and verify that the claims in this document are true.

If you find that any behavior contradicts what is documented here, please report it as a security issue.
