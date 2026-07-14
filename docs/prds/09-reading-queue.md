# PRD 09 — Reading Queue

**Status:** ready.
**Scope:** `AppDelegate.swift` only. Zero core touch.
**Risk:** none — uses existing `engine.speak` + the existing `.oratorSpeechFinished` notification.

## Problem

Users want to line up several things and let Orator read them back-to-back, instead of one selection at a time.

## Solution

An in-memory queue of texts. Add selections/clipboard to it; Orator reads them in order, auto-advancing when each finishes. A manual stop halts advancing but keeps the queue.

## Requirements (all in `AppDelegate.swift`)

### State
```swift
private var readingQueue: [String] = []
private var queuePlaybackActive = false
```

### Menu (`rebuildMenu`, engine-available section)
- **"Add Selection to Queue"** → captures the selection (reuse `captureSelectedText`) and appends it.
- **"Add Clipboard to Queue"** → appends `NSPasteboard.general.string(forType: .string)` if non-empty.
- A **"Queue"** submenu:
  - A disabled header line showing the count (e.g. "3 items" or "Empty").
  - Each queued item as a disabled row titled with its first ~40 chars (single line).
  - Separator, then: **"Play Queue"** (shown when the queue is non-empty and not currently active), **"Stop Queue"** (shown when active), **"Clear Queue"** (when non-empty).

### Behavior
- **Adding an item:** append it. If nothing is currently speaking and `queuePlaybackActive == false`, start queue playback immediately (natural "add and it starts reading"). If already playing, just enqueue.
- **`startQueuePlayback()`:** set `queuePlaybackActive = true`, then `playNextInQueue()`.
- **`playNextInQueue()`:** if `readingQueue` is empty → set `queuePlaybackActive = false`, rebuild menu, return. Otherwise remove the first item and speak it exactly the way `toggleSpeech` does after capture (dispatch `engine.speak(text)` on a background queue). Rebuild the menu so the remaining count updates.
- **Auto-advance:** add an observer for `.oratorSpeechFinished`. In the handler, if `queuePlaybackActive` is `true`, call `playNextInQueue()`. (There is already a separate `.oratorSpeechFinished` observer for the icon — add a second one; do not disturb the existing one.)
- **Manual stop must halt the queue:** anywhere the user manually stops playback — the `toggleSpeech()` stop branch (`if engine.isSpeaking { engine.stop() }`) — set `queuePlaybackActive = false` BEFORE calling `engine.stop()`, so the resulting `.oratorSpeechFinished` does not auto-advance. The remaining queue stays intact so "Play Queue" can resume.
- **"Stop Queue"**: set `queuePlaybackActive = false`, then `engine.stop()`.
- **"Clear Queue"**: empty `readingQueue`, rebuild menu (does not stop current playback).

### Notes
- The queue is in-memory only (not persisted) — fine for v1.
- Distinguishing natural finish from manual stop relies solely on the `queuePlaybackActive` flag being cleared before any user-initiated `engine.stop()`. Get that ordering right; it's the crux.

## Landmines — DO NOT TOUCH

1. **Do not modify `OratorEngine.swift`.** Use `engine.speak` / `engine.stop` / `engine.isSpeaking` and observe `.oratorSpeechFinished` as-is.
2. Do not touch `HotkeyManager.swift`, `TextChunker.swift`, `ReadableText.swift`, `Pronunciations.swift`, `AppVoiceProfiles.swift`, `FileTextExtractor.swift`, or the build scripts.
3. Only `AppDelegate.swift`.
4. Foundation + AppKit only. Swift 6.2 strict concurrency; `AppDelegate` is `@MainActor`.
5. Do not break the existing `.oratorSpeechFinished` icon observer, `toggleSpeech`, or the per-app-voice override logic in `toggleSpeech` (which runs before `engine.speak`). The queue's `playNextInQueue` should apply the same per-app/global voice resolution the normal path uses if that is factored into a helper; if it is inline in `toggleSpeech`, it is acceptable for queued items to use the current engine voice/speed for v1 — do NOT duplicate or move that logic if it risks breakage.

## Build & verify

- `./scripts/build-app.sh` (xcodebuild; if sandbox-blocked, ensure it type-checks and say so).
- Do not commit/sign/release. Report the diff: state, menu items, and the queue methods.

## Out of scope

- Persisting the queue across launches
- Reordering / removing individual items
- Adding files to the queue (a later PRD could add "Add File to Queue…")
