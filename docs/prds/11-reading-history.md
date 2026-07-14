# PRD 11 — Reading History

**Status:** ready.
**Scope:** `AppDelegate.swift` + one new file. Zero core touch.
**Privacy:** local only, capped at 20, clearable, with an off switch. Never leaves the machine.

## Problem

Users want to re-listen to something they recently had read aloud without re-selecting it.

## Solution

A small, capped, local history of recently-read texts. A "History" submenu lists them; clicking one reads it again. Includes "Clear History" and a "Remember Reading History" on/off toggle (default on). Because read-aloud text can be sensitive, the toggle and Clear are first-class.

## Requirements

### 1. New file `Sources/Orator/ReadingHistory.swift`

Mirror the `Pronunciations` store pattern (`@unchecked Sendable`, `NSLock`, JSON in `UserDefaults`):

```swift
struct HistoryEntry: Codable, Sendable { let title: String; let text: String }

final class ReadingHistory: @unchecked Sendable {
    func add(_ text: String)          // trims; ignores empty; dedupes if identical to most-recent; caps to 20 most-recent
    var entries: [HistoryEntry]       // most-recent first
    func clear()
}
```
- Persist under `UserDefaults` key `"readingHistory"` as JSON `Data`.
- `title` = first ~50 characters of the (whitespace-collapsed) text, single line.
- Cap at 20; dropping oldest.

### 2. Recording (in `AppDelegate`)

Add `private func recordHistory(_ text: String)` that, **only if the "remember history" pref is enabled**, calls `history.add(text)` then rebuilds the menu.

Call `recordHistory(text)` at these user-initiated read points, using the text actually being read:
- `toggleSpeech` — right where it dispatches `engine.speak(text)` after a successful capture.
- `speakClipboardText`.
- `readFile` — with the extracted file text.

(Do NOT record in `playNextInQueue`; queued items are out of scope for v1. Do NOT record previews.)

### 3. Pref + menu (`AppDelegate`)

- `private var rememberHistory: Bool` loaded from `UserDefaults` key `"rememberHistory"` (default `true` if absent), near the other prefs.
- A **"History"** submenu:
  - If empty: a single disabled "No recent reads" row.
  - Otherwise: up to 20 rows titled with each entry's `title`; clicking a row reads that entry's full text (dispatch `engine.speak` on a background queue, same as elsewhere).
  - Separator, then a checkmark **"Remember Reading History"** (state = `rememberHistory`; toggling persists to `"rememberHistory"` and rebuilds), and **"Clear History"** (calls `history.clear()` + rebuild).

## Landmines — DO NOT TOUCH

1. Do not modify `OratorEngine.swift`. Use `engine.speak` as-is.
2. Do not touch `HotkeyManager.swift`, `TextChunker.swift`, `ReadableText.swift`, `Pronunciations.swift`, `AppVoiceProfiles.swift`, `FileTextExtractor.swift`, or the build scripts.
3. Only `AppDelegate.swift` + new `ReadingHistory.swift`.
4. Foundation + AppKit only. Swift 6.2 strict concurrency; `AppDelegate` is `@MainActor`; the store is `@unchecked Sendable` + `NSLock`.
5. Do not break `toggleSpeech`, the reading queue, continuous-reading, or per-app voices. Recording is an additive call only.
6. Do not overwrite `"voice"`/`"speed"` defaults.

## Build & verify

- `./scripts/build-app.sh` (xcodebuild; if sandbox-blocked, ensure it type-checks and say so).
- Do not commit/sign/release. Report `ReadingHistory.swift`, the recordHistory calls, and the History submenu.

## Out of scope

- Recording queued/preview reads
- Timestamps / "time ago" display
- Re-export from history
- Search
