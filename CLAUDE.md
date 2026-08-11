# Blackbox

macOS menu bar app that auto-records call audio. Detects calls via CoreAudio per-process audio state polling. Captures system audio via display-wide SCStream (ScreenCaptureKit) and mic via AVAudioEngine as independent pipelines.

## Project Structure

```
Package.swift                              - SPM manifest, macOS 26.1+, Swift 6.2
Sources/
  BlackboxApp.swift                        - @main App, MenuBarExtra, Window scenes, AppDelegate
  AudioMonitor.swift                       - @Observable: call detection (polling), auto/manual recording lifecycle
  AudioMonitorSupport.swift                - RecorderSession protocol, AudioMonitorDependencies (DI), factory types
  AudioRecorder.swift                      - SCStream (system audio) + AVAudioEngine (mic), dual-track capture
  RecordingPipeline.swift                  - AVAssetWriter management, gap filling, tail padding, audio level metering
  AECProcessor.swift                       - DTLN-aec CoreML post-processing: echo cancellation on mic track
  TrackMixdown.swift                       - Post-stop pass: renders the mixed track and remuxes to [mixed, mic, system]
  TranscriptionService.swift               - Soniox async client, RecordingMetadata, RecordingTrackMap (track roles)
  BlackboxTestMode.swift                   - Test mode flags (--ui-test-mode), IPC types for smoke tests
  BlackboxTestController.swift             - File-based IPC controller for smoke test automation
  MainWindowView.swift                     - Main window: TabView with Recordings table + Settings
  SettingsView.swift                       - Settings UI, defaults constants
  OnboardingView.swift                     - First-launch onboarding: permissions walkthrough
  RecordingHUD.swift                       - Floating NSPanel toast (top-right), recording start + save with click-to-reveal
  Log.swift                                - OSLog + file logging, debug export
Info.plist                                 - LSUIElement, NSAudioCaptureUsageDescription, NSMicrophoneUsageDescription
Makefile                                   - build, bundle, dmg, release, install, run, format, test, check, smoke, clean
Tests/
  BlackboxTests.swift                      - PCM conversion, AEC processing, gap filling, resample tests
  AudioMonitorIntegrationTests.swift       - AudioMonitor integration tests with fake dependencies
  RecordingPipelineIntegrationTests.swift  - RecordingPipeline file output, gap fill, tail padding tests
  HardwareSmokeTests.swift                 - End-to-end smoke test via real app bundle (hardware-gated)
  TestSupport.swift                        - TestClock, FakeHUD, MonitorHarness, BlackboxSmokeClient
  Fixtures/Recordings/                     - Reference recordings for AEC regression tests
.claude/skills/
  release-dmg/SKILL.md                     - /release-dmg slash command for full release automation
```

## Build & Run

```sh
make build      # swift build -c release
make bundle     # build + create .app bundle + codesign
make dmg        # bundle + create DMG with Applications symlink
make release    # dmg + notarize + staple
make install    # bundle + copy to /Applications
make run        # bundle + open .app
make test       # swift test (Swift Testing framework)
make check      # format + build + test (full validation)
make smoke-test # bundle + run all tests including hardware smoke (requires audio permissions)
make smoke      # alias for smoke-test
make format     # swift-format --recursive Sources/ Tests/ --in-place
make clean      # remove build artifacts
```

## Code Quality

### Compiler settings (Package.swift)
- `.swiftLanguageMode(.v6)` - strict concurrency, data race safety at compile time
- `.defaultIsolation(MainActor.self)` - all types MainActor by default
- `.treatAllWarnings(as: .error)` - zero warnings policy

### Formatting
- `swift-format` (Apple's formatter, installed via Homebrew)
- Run `make format` before commits
- 2-space indentation (swift-format default)

### No external linters needed
The Swift 6 compiler with strict concurrency + warnings-as-errors catches more real bugs than SwiftLint. swift-format handles style consistency.

## Testing

- **Framework**: Swift Testing (built into Swift 6.0+ toolchain)
- **Run**: `make test` or `swift test`
- **Test target**: `BlackboxTests` in `Tests/` directory
- **Isolation**: Same `defaultIsolation(MainActor.self)` as production code
- Tests find Testing.framework via the xcode-select'd toolchain; do NOT add CLT framework search paths to Package.swift (a version-mismatched CLT breaks every @Test macro with sourceLocation/sourceBounds errors)

### Test categories
- **Unit tests** (`make test`): PCM conversion, gap filling, resample, AEC processing, RecordingPipeline integration. Run without special permissions.
- **AudioMonitor integration tests** (`make test`): Use `MonitorHarness` with `TestClock`, `FakeHUD`, and `TestRecorderFactory` to test call detection, auto/manual recording lifecycle, continuity events, and restart budgets - no real audio hardware needed.
- **Hardware smoke tests** (`make smoke-test`): Launch the real `.app` bundle, drive it via file-based IPC (`BlackboxTestController`), record real audio, verify output file structure. Gated by `BLACKBOX_RUN_HARDWARE_SMOKE=1` env var. Require System Audio Recording + Microphone permissions.

### Test mode infrastructure
The app supports `--ui-test-mode` for smoke tests. `BlackboxTestMode` parses CLI flags, `BlackboxTestController` polls `command.json` and writes `state.json` for IPC. `BlackboxSmokeClient` (in TestSupport.swift) drives the app from the test process.

## Logs

App logs: `~/Library/Logs/Blackbox/blackbox.log`
Crash reports: `~/Library/Logs/DiagnosticReports/Retired/Blackbox-*.ips`

## Pre-Release Checklist

1. **Automated**: `make check` (format + build + test)
2. **Hardware smoke test**: `make smoke-test` (builds bundle, launches app, records real audio, verifies output)
3. **Manual smoke test**: `make install && open /Applications/Blackbox.app`
4. **Verify permissions**: First recording should prompt for System Audio Recording permission
5. **Test auto-recording**: Start any call (Zoom, Meet, etc.) - recording should start when microphone becomes active
6. **Test manual recording**: Menu > Record Now - should record and stop cleanly
7. **Test graceful quit**: Quit via menu while recording - file should be complete (not corrupted)
8. **Test settings**: All settings persist across restart, changes take effect within 5 seconds
9. **Check output files**: M4A files in ~/Library/Application Support/Blackbox/Recordings/, named with timestamp + app name, playable in QuickTime

## Release Process

Use the `/release-dmg <version>` slash command to automate the full release pipeline.

The command handles: version bump (Makefile + Info.plist + CHANGELOG.md), format + build + test, DMG creation, Sparkle signing, git commit + push + tag, GitHub release with changelog notes and appcast.xml.

Version is tracked in two places that must stay in sync:
- `Makefile` - `VERSION = X.Y.Z` (used for DMG filename)
- `Info.plist` - `CFBundleShortVersionString` (shown in app) + `CFBundleVersion` (build number)

Notary uses keychain profile `blackbox` (configured via `xcrun notarytool store-credentials`).
Sparkle reads `SUFeedURL` from Info.plist pointing to `releases/latest/download/appcast.xml`.
A GitHub release does NOT update Homebrew: bump `Casks/blackbox-recorder.rb` in tenequm/homebrew-tap
(version + sha256 of the published DMG). The cask keeps `auto_updates true` because Sparkle
self-updates. Both steps are covered by `/release-dmg`.

## Key Architecture Decisions

- **Polling-only call detection** drives recording lifecycle. Every 3 seconds, CoreAudio Swift wrappers (`AudioHardwareSystem.shared.processes`) enumerate processes with BOTH `isRunningInput` AND `isRunningOutput` (filtering out own PID). Input+output check identifies actual calls, filtering out dictation/Siri/voice memos. No CoreAudio property listeners - polling-only eliminates ~140 lines of listener management code.
- **SCStream system audio capture**: Single display-wide `SCStream` (ScreenCaptureKit) captures the OS-composited audio mix, excluding own PID via `excludesCurrentProcessAudio = true`. Video disabled (2x2, max frame interval). `SCStreamOutput` callback delivers stereo 48kHz Float32 CMSampleBuffer on `audioQueue` and is appended **directly** to a stereo 128 kbps AAC writer input (v0.6.0 parity) - no PCM round-trip, no downmix. `SCStreamDelegate.didStopWithError` maps NSError codes (−3801 permission, −3802/−3821 stopped) to `RecorderFailure`. Requires Screen Recording permission (on macOS 26.1+, this also grants audio capture).
- **AVAudioEngine mic capture**: Independent mic pipeline via `inputNode.installTap()`. Can fail without affecting system audio. Device following via `AVAudioEngineConfigurationChange` notification (reinstalls tap, sub-second gap, same file). Device latency offset (D9) applied as PTS shift to align mic with system audio.
- **AudioRecorder is an `actor` with custom `DispatchSerialQueue` executor.** All actor-isolated state runs on `audioQueue`. SCStream and AVAudioEngine tap callbacks dispatch to `audioQueue` and use `assumeIsolated` to bridge into actor isolation. No `nonisolated(unsafe)` needed.
- **RecordingPipeline** (`@unchecked Sendable`) handles AVAssetWriter management, gap filling, tail padding, and audio level metering. Extracted from AudioRecorder for testability. All access serialized by AudioRecorder's `audioQueue` - the pipeline has no internal synchronization. `nonisolated(unsafe)` state is safe because AudioRecorder guarantees single-threaded access.
- **AudioMonitor dependency injection**: `AudioMonitorDependencies` struct injects all external dependencies (recorder factory, HUD, settings, clock, sleep, process query). Enables deterministic testing via `MonitorHarness` with `TestClock` and `TestRecorderFactory`. `RecorderSession` protocol abstracts over `AudioRecorder` for test doubles.
- **Live capture writes 2 tracks**: Track 0 = system audio (2ch stereo 48kHz 128 kbps AAC, SCStream buffers appended directly). Track 1 = mic (1ch mono 48kHz 64 kbps AAC, resampled/downmixed via `resampleToMono48k`). Session starts on whichever track delivers the first sample. Gap fill (D8), leading silence, and tail padding run on the mic track only (v0.6.0 parity).
- **3-track final format**: after the recorder stops, `TrackMixdown` renders the file to `[0: mixed, 1: mic, 2: system]` and replaces it atomically. Track 0 exists because single-stream consumers (`ffmpeg` without `-map`, most players' default track pick) read track 0 - with system audio there, the local voice was missing. The mixed track is exported through `AVMutableComposition` + `AVAssetExportPresetAppleM4A`; mic and system are remuxed **passthrough**, so their samples are never re-encoded. Fire-and-forget: on any failure the original 2-track file is left intact and playable.
- **Track roles live in `metadata.json`, not in positions.** `RecordingTrackMap` resolves index -> `RecordingTrackRole` and falls back to the layouts that shipped earlier (2 tracks -> `[system, mic]`; 3 tracks without declared roles -> pre-v0.7.0 `[system, perApp, mic]`). Every consumer - AEC reference selection, transcription, the player's track picker - MUST go through it. Positional heuristics are a trap here: the old `tracks[count - 1]` "mic is last" rule silently inverts mic and system under the new layout.
- **Echo cancellation post-processing**: After recording stops, DTLN-aec CoreML (256-unit model) processes the mic track using the far-end track as the AEC reference, both resolved by role. Writes `audio-processed.m4a` alongside the original (fixed `[system, mic]` layout, which the 2-track legacy fallback resolves correctly). Fire-and-forget: errors are logged, original is never modified.
- **Transcription is per-track**: mic and far end are uploaded to Soniox as two concurrent async jobs - mic with diarization OFF (one known speaker, rendered as `-1` / "Я"), far end with diarization ON - then merged on a shared timeline. The mic track carries no cross-talk, so the local speaker is attributed exactly rather than guessed from a mixed file. Language hints come from Settings (`transcriptionLanguages`, default `ru`). Files with no mic track fall back to mixing and a single diarized job.
- **`applicationShouldTerminate` returns `.terminateLater`** to allow async cleanup (stop AVAudioEngine, stop SCStream capture, finalize AVAssetWriter) before process exit. 8-second timeout with `hasReplied` flag to prevent double-reply race.
- **Auto-recovery**: `RecorderFailure` enum categorizes stream errors (system stopped, permission denied). AudioMonitor auto-restarts on recoverable failures.
- **Crash safety**: `movieFragmentInterval` on AVAssetWriter writes fragment headers every 10s, making partial files recoverable.

## Concurrency Model

With `defaultIsolation(MainActor.self)`:
- All types are `@MainActor` by default (BlackboxApp, AudioMonitor, SettingsView)
- AudioMonitor is purely MainActor-isolated (polling-only, no C callbacks)
- AudioRecorder is an `actor` with custom `DispatchSerialQueue` executor (`audioQueue`). All actor-isolated state accessed on `audioQueue` - same runtime behavior as the previous `nonisolated(unsafe)` approach, but with compile-time safety
- RecordingPipeline is `@unchecked Sendable` with `nonisolated(unsafe)` state - safe because all access is serialized on AudioRecorder's `audioQueue`
- SCStream sample handler (via `SCStreamProxy`, a thin NSObject adapter) dispatches to `audioQueue.async` with `assumeIsolated` for direct passthrough to RecordingPipeline (no downmix)
- SCStream stop/error callbacks hop through `audioQueue.async` to `assumeIsolated` for `RecorderFailure` routing
- AVAudioEngine tap callback dispatches to `audioQueue.async` with `assumeIsolated` to serialize with SCStream callbacks
- AVAudioEngine config change observer fires via `Task { await ... }`, actor-isolated `debounceConfigChange` uses `asyncAfter` with `assumeIsolated` for the delayed handler
- D12 supplemental mic-recovery signals feed the same debounced restart: `kAudioHardwarePropertyDefaultInputDevice` CoreAudio listener (dispatch queue = `audioQueue`, block uses `assumeIsolated`) and a `DispatchSourceTimer` watchdog on `audioQueue` that trips when mic buffers stall >2 s; all three sources call `requestMicReinstall(source:)` which logs the source and delegates to `debounceConfigChange`

## Cross-Model Collaboration (Codex)

Claude Code can delegate work to OpenAI Codex via `.claude/bin/codex-bridge.sh`.
Both run on subscriptions - no API keys. The bridge script unsets `OPENAI_API_KEY`
so Codex never accidentally uses your project's API key for billing.

**Commands:**

| Command | Purpose |
|---------|---------|
| `/collab <task>` | Full collaboration: think, build, or debug with Codex |
| `/collab-review` | Quick second opinion from Codex on current changes |

**How it works:** Claude calls `codex exec` via bash. Codex's response streams
directly into Claude's context. Claude reads it, reasons about it, synthesizes.
No tmux, no file polling, no third-party tools. Build tasks run asynchronously
in the background so the user can keep talking to Claude while Codex works.

**Bridge modes:**
- `codex-bridge.sh think "prompt"` - read-only, for debate and review (sync)
- `codex-bridge.sh build "prompt"` - workspace-write, for implementation (async)
- `codex-bridge.sh build "prompt" path/to/spec.md` - build from spec file (async)

**Build specs** go in `.collab/specs/`. **Reports** go in `.collab/reports/`.

**Rules:**
- Never assign overlapping files to both Claude subagents and Codex
- Always run your test suite after Codex builds - never trust the self-report
- Keep Codex prompts concise (500 words max) - it has no session memory
- Synthesize Codex output for the user, don't relay it raw
- Compact context before starting a collab workflow
- Break large builds into 2-3 small focused Codex calls (max 3 files each)
