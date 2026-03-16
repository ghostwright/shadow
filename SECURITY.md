# Security

Shadow captures sensitive data. Screen recordings, keystrokes, audio, accessibility tree snapshots, clipboard contents, terminal output. This document explains exactly how that data is handled, what protections exist, and where the current limitations are.

## Data Storage

All captured data lives at `~/.shadow/data/` on your local file system. Nothing is uploaded, synced, or transmitted to any server. There is no Shadow account, no cloud service, no telemetry endpoint.

```
~/.shadow/
  data/
    events/          MessagePack event logs (zstd compressed, hourly rotation)
    media/video/     H.265 screen recordings (per display)
    media/audio/     Audio segments (mic + system)
    media/keyframes/ Retained keyframes from expired video (warm tier)
    indices/         SQLite timeline, Tantivy search, CLIP vector embeddings
    context/         Episode summaries, daily/weekly records
    ax_snapshots/    Accessibility tree snapshots (JSON)
    procedures/      Learned workflow patterns
    proactive/       Proactive analysis run records and suggestions
  models/            Downloaded ML models (LLM, embeddings, vision, whisper)
```

The data directory is owned by your macOS user account and protected by standard Unix file permissions. Any user with access to your home directory can read this data.

## Keystroke Security

Shadow monitors keystrokes system-wide via `CGEventTap`. This is the most sensitive capture track.

**Password detection.** Before any keystroke reaches the event pipeline or storage, Shadow checks the currently focused UI element via the Accessibility API. If the element is `AXSecureTextField` (the standard macOS type for password inputs, 2FA fields, and credit card fields), keystroke recording pauses immediately. A `secure_field_active` event is recorded instead of the actual characters. When focus leaves the secure field, normal recording resumes.

This detection happens at the CGEventTap callback level, before the event is serialized or written to disk. Passwords are never stored, even temporarily.

**Limitation.** This protection depends on apps correctly marking their password fields as `AXSecureTextField`. Most apps do (Safari, Chrome, 1Password, system dialogs). Custom-rendered password fields in some Electron apps may not. If you are concerned about a specific app, you can exclude it from capture entirely.

## Screen Recording

Shadow captures screen content across all displays using ScreenCaptureKit at 0.5 frames per second. This captures everything visible on screen, including sensitive content (banking sites, medical records, private messages, personal photos).

**What you can do:**
- Pause recording at any time from the menu bar
- Exclude specific apps from capture (coming soon)
- Delete any time range of data from `~/.shadow/data/`
- Lock your screen when stepping away (Shadow pauses on screen lock)

**What Shadow does not do:**
- Shadow does not capture content from Private Browsing or Incognito windows differently. If it is on screen, it is captured.
- Shadow does not selectively filter screen content. The capture is all-or-nothing per display.

## Audio

Microphone and system audio capture is mic-triggered. Shadow does not record silence. Recording starts when the microphone becomes active (meeting, voice call, dictation) and stops 30 seconds after the mic goes quiet.

Audio is transcribed on-device using WhisperKit (Apple Speech as fallback). Transcripts are stored locally. Raw audio segments are retained according to the three-tier retention policy (hot: 7 days full, warm: 8-30 days transcripts only, cold: 31+ days indices only).

## API Keys

If you choose to use cloud LLM features (Claude, GPT), your API key is stored in the macOS Keychain, which is hardware-backed by the Secure Enclave on Apple Silicon. The key is never logged, never written to disk outside the Keychain, and never transmitted except in authenticated API requests to the provider you configured.

Cloud features are entirely opt-in. If you do not provide an API key, Shadow runs completely on-device using local MLX models.

## What Data Reaches External Servers

**By default: nothing.** Shadow is fully local.

**If you opt into cloud LLM features:** When you use Claude or GPT for agent queries, meeting summaries, or proactive analysis, the specific context for that request is sent to the LLM provider (Anthropic or OpenAI). This includes the text of your query and relevant context (episode summaries, recent activity). Screenshots, raw audio, and full keystroke logs are never sent to cloud providers.

A consent gate prevents cloud features from activating without explicit user approval. The gate is enforced in code and cannot be bypassed by configuration.

## Agent Actions

Shadow's agent system and Mimicry engine can take actions on your computer (clicking, typing, scrolling). These actions go through a SafetyGate that performs pre-action checks before execution. Post-action verification confirms the action had the intended effect. An undo manager allows reverting agent actions.

When the agent takes actions, those synthetic events are tagged internally and excluded from Shadow's own learning pipeline. Shadow learns from your behavior, not from its own actions.

## Encryption at Rest

**Current status: not implemented.** Data at `~/.shadow/data/` is stored unencrypted on your local file system. It is protected by macOS user account permissions and FileVault (if enabled on your Mac).

**Planned:** AES-256-GCM encryption using a key derived from your macOS login via the Secure Enclave and CryptoKit. This is on the roadmap but not yet shipped.

If you use FileVault (System Settings > Privacy & Security > FileVault), your entire disk is encrypted at rest, which covers Shadow's data directory.

## Reporting Vulnerabilities

If you discover a security vulnerability in Shadow, please report it responsibly.

- Email: cheemawrites@gmail.com
- Subject: "Shadow Security"
- Please include steps to reproduce and the potential impact

We will acknowledge receipt within 48 hours and work with you on a fix before any public disclosure.
