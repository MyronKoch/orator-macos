# PRD 12 — Shortcuts / App Intents

**Status:** ready (compile + structure). Runtime Shortcuts registration to be verified by maintainer.
**Scope:** new `Sources/Orator/OratorIntents.swift` + a small `AppDelegate.swift` addition.
**Risk to core:** none. Intents call a new thin `AppDelegate` helper that uses existing `engine` methods.

## Problem

Power users want to drive Orator from the macOS Shortcuts app and Automation: "Speak Text", "Speak Clipboard", "Stop Speaking".

## Solution

Adopt App Intents. Expose a few intents plus an `AppShortcutsProvider`. Intents bridge to the running app via a shared reference and thin helpers.

## Requirements

### 1. Bridge in `AppDelegate.swift`

- Add `static weak var shared: AppDelegate?` and set `AppDelegate.shared = self` at the start of `applicationDidFinishLaunching`.
- Add thin `@MainActor` helpers (reusing existing logic where possible):
  - `func speakText(_ text: String)` — trims; if empty do nothing; otherwise `recordHistory(text)` then dispatch `engine?.speak(text)` on a background queue exactly like the other paths.
  - `func speakClipboard()` — reads `NSPasteboard.general.string(forType: .string)` and calls `speakText`.
  - `func stopSpeaking()` — sets `queuePlaybackActive = false` then `engine?.stop()`.

### 2. New file `Sources/Orator/OratorIntents.swift`

`import AppIntents`. Define:

```swift
struct SpeakTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Speak Text"
    @Parameter(title: "Text") var text: String
    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.shared?.speakText(text)
        return .result()
    }
}

struct SpeakClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Speak Clipboard"
    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.shared?.speakClipboard()
        return .result()
    }
}

struct StopSpeakingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Speaking"
    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.shared?.stopSpeaking()
        return .result()
    }
}

struct OratorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SpeakTextIntent(), phrases: ["Speak text with \(.applicationName)"], shortTitle: "Speak Text", systemImageName: "waveform")
        AppShortcut(intent: SpeakClipboardIntent(), phrases: ["Speak clipboard with \(.applicationName)"], shortTitle: "Speak Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: StopSpeakingIntent(), phrases: ["Stop \(.applicationName)"], shortTitle: "Stop Speaking", systemImageName: "stop.circle")
    }
}
```

Adjust exact API to whatever compiles cleanly on macOS 15 / Swift 6.2 (App Intents API names have varied across OS versions — if `title`/`appShortcuts` need `static let` or a different signature to compile, do that; the structure above is the target).

### 3. Do not change the build scripts

If App Intents requires a metadata build phase that xcodebuild-from-SwiftPM does not run, that is a known follow-up for the maintainer — do NOT modify `scripts/build-app.sh` to try to fix it. Just make the code compile and be structurally correct.

## Landmines — DO NOT TOUCH

1. Do not modify `OratorEngine.swift` — use `engine.speak`/`engine.stop` via the new `AppDelegate` helpers.
2. Do not touch `HotkeyManager.swift`, `TextChunker.swift`, `ReadableText.swift`, `Pronunciations.swift`, `AppVoiceProfiles.swift`, `FileTextExtractor.swift`, `ReadingHistory.swift`, or the build scripts.
3. Only `AppDelegate.swift` + new `OratorIntents.swift`.
4. System frameworks only (AppIntents, AppKit, Foundation).
5. Swift 6.2 strict concurrency; `AppDelegate` is `@MainActor`; intents hop to `@MainActor` in `perform()`.
6. Reuse `recordHistory`, `queuePlaybackActive`, existing dispatch patterns — do not duplicate or alter queue/history/per-app-voice logic.

## Build & verify

- `./scripts/build-app.sh` (xcodebuild; if sandbox-blocked, ensure it type-checks and say so). **Getting it to compile cleanly is the bar for this PRD.**
- Do not commit/sign/release. Report `OratorIntents.swift` and the `AppDelegate` bridge additions.

## Out of scope

- Intents that return audio files
- Parameterized voice/speed in intents
- Focus/automation triggers
