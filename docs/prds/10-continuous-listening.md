# PRD 10 — Continuous Listening Mode

**Status:** ready. Builds on the reading queue (PRD 09, already implemented).
**Scope:** `AppDelegate.swift` only. Zero core touch.

## Problem

The reading queue auto-advances by default. Users want control over that: a hands-free "continuous" mode that reads straight through, versus a one-at-a-time mode that pauses after each item.

## Solution

A persisted **"Continuous Reading"** toggle. When ON (default), the queue advances automatically through every item. When OFF, the queue stops after each item and waits for the user to resume with "Play Queue".

## Requirements (all in `AppDelegate.swift`)

### State
```swift
private var continuousReading: Bool   // loaded from UserDefaults key "continuousReading", default true
```
Load it in the same place other prefs are loaded (near where `"voice"`/`"speed"` are read). If the key is absent, default to `true`.

### Menu
Add a checkmark menu item **"Continuous Reading"** (near the Queue items). Its `.state` reflects `continuousReading`. Toggling it flips the bool, persists to `UserDefaults` (`"continuousReading"`), and rebuilds the menu.

### Behavior
In the queue's `.oratorSpeechFinished` auto-advance handler (from PRD 09), change the logic to:
- if `queuePlaybackActive` is `true` **and** `continuousReading` is `true` → `playNextInQueue()` (current behavior).
- if `queuePlaybackActive` is `true` **and** `continuousReading` is `false` → set `queuePlaybackActive = false` and rebuild the menu (stop after the finished item; the remaining queue stays intact so "Play Queue" resumes).

No other queue behavior changes. Adding items and "Play Queue" still work as before; when continuous is OFF, "Play Queue" plays exactly one item then stops.

## Landmines — DO NOT TOUCH

1. Do not modify `OratorEngine.swift` or any file other than `AppDelegate.swift`.
2. Do not touch the build scripts.
3. Do not break the reading-queue logic from PRD 09, the manual-stop ordering, the existing icon observer, or per-app voices.
4. Foundation + AppKit only. Swift 6.2 strict concurrency; `AppDelegate` is `@MainActor`.
5. Do not overwrite `"voice"`/`"speed"` defaults.

## Build & verify

- `./scripts/build-app.sh` (xcodebuild; if sandbox-blocked, ensure it type-checks and say so).
- Do not commit/sign/release. Report the state, the toggle menu item, and the changed auto-advance handler.

## Out of scope

- Auto-queuing new selections while in continuous mode
- Repeat / loop
