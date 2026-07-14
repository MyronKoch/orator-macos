# PRD 06 — Voice Preview in Per-App Voices

**Status:** ready for implementation
**Scope:** `AppDelegate.swift` only.
**Risk to core:** none. The engine change it depends on is already done (a `speed:` param was added to `synthesizeToFile`). You only call existing public methods.

## Problem

Voice names (`af_alloy`, `af_aoede`, `af_heart`…) mean nothing until you hear them. In the Per-App Voices window, the user picks a voice for an app with no way to know what it sounds like. Add a **Preview** button per row so they can audition the selected voice+speed before committing.

## What already exists (use as-is, DO NOT modify)

`OratorEngine.synthesizeToFile` now accepts an optional `speed:`:

```swift
func synthesizeToFile(
    _ text: String,
    voiceName: String? = nil,
    speed: Float? = nil,
    to url: URL,
    progress: (@Sendable (Double) -> Void)? = nil,
    completion: @escaping @Sendable (Result<URL, Error>) -> Void
)
```

It renders an AAC `.m4a` offline, off the main thread, isolated from live playback, and calls `completion` on the main queue. Use it to render a short sample; do not add engine methods.

## Requirements (all in `AppDelegate.swift`)

### 1. A preview capability owned by `AppDelegate`

Add a method on `AppDelegate`:

```swift
func previewVoice(_ voiceName: String, speed: Float)
```

It should:
- Render a short fixed sample sentence — e.g. `"Hello, this is the \(displayName) voice. The quick brown fox jumps over the lazy dog."` or simply a constant like `"The quick brown fox jumps over the lazy dog."` — via `engine?.synthesizeToFile(sample, voiceName: voiceName, speed: speed, to: tempURL, completion:)`.
- Write to a temp file: `FileManager.default.temporaryDirectory.appendingPathComponent("orator-preview.m4a")` (overwrite each time).
- On `.success(url)`, play it with a **standalone `AVAudioPlayer`** held in a stored property on `AppDelegate` (so it isn't deallocated mid-play). Do **not** route preview through the engine's player — keep it fully separate from live playback.
- On `.failure`, do nothing noisy (optionally `oratorLog`).
- Cheap debounce: if a preview render is already in flight, ignore new requests until it finishes (a simple `Bool` flag is fine), so rapid clicks don't stack.

### 2. Pass a preview closure into the editor

The `AppVoiceProfilesEditor` should not reach into the engine. Give its initializer a closure:

```swift
onPreview: @escaping (_ voiceName: String, _ speed: Float) -> Void
```

Wire it at the `openPerAppVoices()` call site to `{ [weak self] voice, speed in self?.previewVoice(voice, speed: speed) }`.

### 3. Preview button per row

In `AppVoiceProfilesEditor`, add a **Preview** control for each row. Simplest clean approach: a new narrow **"Preview"** table column (or place a small speaker-style button next to the Voice pop-up). On click, call `onPreview(row.profile.voice, row.profile.speed)` for that row. Reuse the row-tag pattern already used by the Voice/Speed pop-ups so the button maps to the correct row.

Label it `"▶︎ Preview"` or use `NSImage(systemSymbolName: "play.circle")` for the button image. Keep the visual style consistent with the existing Remove button.

### 4. Behavior

- Clicking Preview plays the currently-selected voice+speed for that row (whatever the pop-ups show), so the user hears exactly what will be saved.
- It's fine if there's a ~1s delay before audio (synthesis + load). Optional nicety: briefly disable the button until playback starts, but not required.

## Landmines — DO NOT TOUCH

1. Modify **only `AppDelegate.swift`**. Do not change `OratorEngine.swift` (the `speed:` param is already there), `AppVoiceProfiles.swift`, or any other file.
2. Do not touch `HotkeyManager.swift`, `TextChunker.swift`, `Pronunciations.swift`, `ReadableText.swift`, or the build scripts.
3. Do not route preview audio through the engine's `player`/`audioEngine` — use a separate `AVAudioPlayer`.
4. No third-party dependencies. Foundation + AppKit + AVFoundation only.
5. Swift 6.2 strict concurrency ON; `AppDelegate` and the editor are `@MainActor`. The `synthesizeToFile` completion already hops to the main queue.
6. Do not overwrite the global `"voice"`/`"speed"` UserDefaults keys.

## Build & verify

- Build via `./scripts/build-app.sh` (xcodebuild; NOT `swift build`). If the sandbox blocks it, ensure it type-checks and say so.
- Do not sign, notarize, commit, or release — leave changes in the working tree.
- Report changes; paste `previewVoice`, the editor initializer/closure wiring, and the Preview button/cell code.

## Out of scope

- Preview buttons inside the dropdown menu items themselves (AppKit pop-up menu items don't support embedded buttons cleanly — a per-row Preview button is the intended design)
- Caching/preloading samples
