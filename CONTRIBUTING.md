# Contributing to Shadow

Shadow is a working product being open-sourced. The capture pipeline, storage engine, search, and intelligence layers are tested and running. We welcome contributions that make Shadow better, more reliable, and more useful.

## Getting Started

### Prerequisites

- Apple Silicon Mac (M1 or later)
- macOS 14 (Sonoma) or later
- Xcode 16.4+
- Rust via [rustup](https://rustup.rs/)
- XcodeGen (`brew install xcodegen`)
- Python 3.8+ (for CLIP model provisioning)

### Build from source

```bash
git clone https://github.com/ghostwright/shadow.git
cd shadow

# Build Rust storage engine and generate Swift bindings
./scripts/build-rust.sh

# Download CLIP models (~190 MB, one-time)
pip3 install huggingface_hub
python3 scripts/provision-clip-models.py

# Generate Xcode project and build
cd Shadow && xcodegen generate && cd ..
xcodebuild -project Shadow/Shadow.xcodeproj -scheme Shadow -configuration Debug build

# Launch
open ~/Library/Developer/Xcode/DerivedData/Shadow-*/Build/Products/Debug/Shadow.app
```

### Run tests

```bash
# Rust tests (109 tests)
cd shadow-core && cargo test

# Swift tests (1,091 tests)
xcodebuild -project Shadow/Shadow.xcodeproj -scheme Shadow -configuration Debug test
```

### After a rebuild

Every ad-hoc rebuild changes the binary signature, which invalidates macOS TCC permissions. Run the reset script to re-grant:

```bash
scripts/reset-permissions.sh
```

This resets permissions and onboarding state. It does NOT delete captured data at `~/.shadow/data/`.

## Where Help Is Needed

### Testing
- Different hardware: M1, M2, M3, M4 (different RAM, GPU core counts)
- Multi-display setups (2+ monitors, hot-plug during recording)
- Edge cases: sleep/wake cycles, display connect/disconnect, long recording sessions
- Different permission grant sequences during onboarding

### Episode Intelligence
- Smarter activity boundary detection (currently time + app-switch based)
- Cross-episode linking (connecting related work across days)
- Better LLM summaries with fewer hallucinations
- Episode clustering by project/topic

### Memory and Search
- Memory graph construction on top of episodes (connecting people, projects, commitments)
- Better search ranking and result presentation
- Faster vector search for large embedding collections

### MCP Server
- Exposing Shadow's knowledge to any AI agent via Model Context Protocol
- Designing the right tool interface (what queries should be supported)
- Privacy controls for MCP access (scoping, filtering, consent)

### New Capture Tracks
- Browser extensions for richer DOM/tab context
- IDE plugins for LSP events (completions, diagnostics, refactors)
- Clipboard content type detection (code vs text vs URL vs image)

### Proactive Analysis
- Better models for context-switch detection and focus scoring
- Meeting follow-up tracking (commitments made vs fulfilled)
- Custom user-defined analysis rules

### Documentation
- Architecture deep-dives for specific subsystems
- API documentation for the Rust storage engine
- Guide for building on top of Shadow's data

## How to Contribute

### Pull Requests

1. Fork the repo
2. Create a branch from `main` (`git checkout -b your-feature`)
3. Make your changes
4. Run both test suites (Rust + Swift) and make sure they pass
5. Open a PR against `main`
6. Tag [@mcheemaa](https://github.com/mcheemaa) for review

### What makes a good PR

- Focused on one thing. Don't mix a bug fix with a feature.
- Tests included when possible. Shadow has 1,200 tests and we want to keep that bar.
- Clear description of what changed and why.
- If it touches the capture pipeline, mention what you tested (which permissions, which hardware).

### Code Style

- **Swift 6** strict concurrency. `@MainActor` for UI and AppDelegate code. Actors for shared mutable state.
- **No force unwraps** except in tests.
- All logging via `Logger(subsystem:category:)` (stderr), never `print()`.
- No app-specific hacks. Fixes should be generic.
- Comments explain WHY, not WHAT.

### Recipes and Workflows

If you have learned procedures or workflow patterns that work well, we would love to see them contributed as examples.

## Architecture Overview

```
Shadow/Shadow/           Swift app source
  App/                   AppDelegate, permissions, recording state
  Capture/               Screen, audio, input, window tracking, OCR, CLIP, transcription
  Intelligence/
    Agent/               25-tool runtime, orchestrator, task decomposition
    Context/             Heartbeat, episode synthesis, context store
    Grounding/           AX + VLM grounding oracle, LoRA trainer
    LLM/                 Multi-provider orchestrator, local MLX, cloud providers
    Memory/              Semantic + directive memory stores
    Mimicry/             VisionAgent, procedure executor, safety gates
    Proactive/           Live analyzer, trust tuner, policy engine
    Summary/             Meeting summarization
  UI/                    Menu bar, search, timeline, onboarding, diagnostics, settings

shadow-core/src/         Rust storage engine
  lib.rs                 UniFFI exports
  search.rs              Tantivy full-text search
  timeline.rs            SQLite timeline index
  vector.rs              CLIP vector embeddings
  workflow_extractor.rs  Behavioral pattern extraction
  behavioral.rs          Behavioral sequence search
  retention.rs           3-tier storage lifecycle
  storage.rs             MessagePack event log writer

scripts/                 Build, provisioning, and development tools
```

## Questions?

Open an issue or start a discussion. We are building this in the open and want to hear what you think.
