# PRD 02 — Audiobook / Audio Export

**Status:** ready for implementation (UI layer only)
**Scope:** UI + file handling. The synthesis core is already implemented.
**Risk to core:** none — the engine method already exists; you only call it.

## Problem

Users want to turn an article or any selected text into an audio file they can listen to later (an audiobook / personal podcast episode).

## What already exists (DO NOT reimplement)

`OratorEngine` already has a finished, tested method — use it exactly as-is:

```swift
func synthesizeToFile(
    _ text: String,
    voiceName: String? = nil,   // nil = current voice
    to url: URL,
    progress: (@Sendable (Double) -> Void)? = nil,   // 0.0...1.0, delivered on main queue
    completion: @escaping @Sendable (Result<URL, Error>) -> Void   // delivered on main queue
)
```

It writes an AAC `.m4a`, runs off the main thread, serializes safely with live playback, and delivers `progress`/`completion` on the main queue. You do not need to know how it works — just call it.

## Requirements (all in `AppDelegate.swift`)

### 1. Menu items

In `rebuildMenu()`, add two items in the engine-available section (near "Speak Clipboard"):
- **"Export Selection to Audio…"** — captures the current selection via the existing `captureSelectedText` path, then exports.
- **"Export Clipboard to Audio…"** — exports the current `NSPasteboard.general` string.

### 2. Save panel

On click, show an `NSSavePanel`:
- Default filename: derive from the first ~40 chars of the text, sanitized to a safe filename, else `"Orator Audio"`. Extension `.m4a`.
- Allowed content type: `.mpeg4Audio` (UTType). Default directory: user's Music folder if available, else Downloads.
- If the user cancels, do nothing.

### 3. Run the export

- Call `engine.synthesizeToFile(text, to: chosenURL, progress:, completion:)`.
- While running, reflect progress unobtrusively: update the menu bar status item's tooltip to `"Exporting… NN%"` (round the fraction). Do not block the UI; the method is already async.
- On `.success(url)`: reveal the file in Finder via `NSWorkspace.shared.activateFileViewerSelecting([url])`, and clear the tooltip.
- On `.failure(error)`: show the error via the existing `showNotification`-style AppleScript notification used elsewhere in this file, and clear the tooltip.

### 4. Empty-text guard

If the captured/clipboard text is empty after trimming, show a brief notification ("Nothing to export") and skip the save panel.

## Landmines — DO NOT TOUCH

1. **Do not modify `OratorEngine.swift`.** The export method and all playback state are finished. Only call the public method.
2. **Do not touch** `HotkeyManager.swift`, `TextChunker.swift`, `Pronunciations.swift`, or the build scripts.
3. **No third-party dependencies.** Foundation + AppKit + AVFoundation + UniformTypeIdentifiers only.
4. **Swift 6.2 strict concurrency is ON.** The `progress`/`completion` closures are `@Sendable` and already hop to the main queue — do UI work directly inside them. `AppDelegate` is `@MainActor`.
5. Match the existing menu-item and window construction style already in `AppDelegate.swift` (programmatic AppKit).

## Build & verify

- Build only via `./scripts/build-app.sh` (xcodebuild; NOT `swift build`).
- Confirm it compiles. Do not sign, notarize, commit, or release — leave changes in the working tree for maintainer review.
- Report which files changed and paste the new `rebuildMenu()` additions plus the export action methods.

## Out of scope (later PRDs)

- Podcast RSS feed generation
- Batch export of multiple items
- Chapter markers / metadata tags
