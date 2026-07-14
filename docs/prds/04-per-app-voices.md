# PRD 04 — Per-App Voice Profiles

**Status:** ready for implementation
**Scope:** `AppDelegate.swift` + one new file. Zero engine changes.
**Risk to core:** none. Uses the existing public `engine.currentVoice` / `engine.speed` settable properties.

## Problem

Users want different voices/speeds in different apps: a slow, clear voice for a code editor; a faster narrator for articles in a browser. Today there is one global voice/speed for everything.

## Solution

Optional per-application profiles. When you trigger a read, if the frontmost app has a saved profile, Orator uses that profile's voice + speed for that utterance; otherwise it uses the global default. The global default (set from the existing Voice/Speed menus) is never disturbed.

## Key design constraints

- **Do not overwrite the global default.** The global voice/speed live in `UserDefaults` under keys `"voice"` / `"speed"` (already used by `loadEngineAsync` / `selectVoice` / `selectSpeed`). Per-app profiles override `engine.currentVoice` / `engine.speed` **transiently, per utterance** — they must not write the `"voice"`/`"speed"` defaults.
- **Capture the target app before the copy.** In `toggleSpeech()`, read `NSWorkspace.shared.frontmostApplication` at the very start (before `captureSelectedText` simulates Cmd+C). That frontmost app is the real target; store its `bundleIdentifier` and `localizedName`.

## Requirements

### 1. New file `Sources/Orator/AppVoiceProfiles.swift`

A `Profile` struct `{ appName: String, voice: String, speed: Float }` and an `AppVoiceProfiles` class (follow the `Pronunciations` pattern — `@unchecked Sendable`, `NSLock`-guarded, persisted to `UserDefaults` under key `"appVoiceProfiles"` as JSON `Data`, keyed by bundle identifier). API:
- `func profile(for bundleID: String) -> Profile?`
- `func set(bundleID: String, appName: String, voice: String, speed: Float)`
- `func remove(bundleID: String)`
- `var all: [(bundleID: String, profile: Profile)]` (sorted by appName)

### 2. Apply at speak time (`AppDelegate.toggleSpeech`)

- At the top of `toggleSpeech()`, capture the frontmost app's bundleID + name; remember them in a stored property `lastReadApp: (bundleID: String, name: String)?`.
- After the selection is captured and before calling `engine.speak(text)`:
  - Read the global default: `defaults.string(forKey: "voice") ?? "af_heart"` and `defaults.float(forKey: "speed")` (fall back to `1.0` if the stored value is `0`).
  - If `profiles.profile(for: bundleID)` exists, set `engine.currentVoice` / `engine.speed` to the profile values; otherwise set them to the global defaults.
  - This override applies for this utterance only; the next global menu selection still works.

### 3. Menu (`rebuildMenu`)

In the engine-available section, add:
- If `lastReadApp` is set: **"Use current voice for [name]"** — saves a profile for that bundleID using the current `engine.currentVoice` / `engine.speed`.
- If a profile exists for `lastReadApp`: **"Clear voice for [name]"** — removes it.
- **"Per-App Voices…"** — opens a management window (see below).

(If `lastReadApp` is nil, show only "Per-App Voices…". Rebuild the menu after saving/clearing so the items update.)

### 4. Management window

A non-modal window (match the existing onboarding / pronunciation window construction style) with a table: **App | Voice | Speed | (Remove)**. Voice and Speed may be shown read-only in v1 with a Remove button per row; add/edit of the voice itself is via the "Use current voice for…" flow. Keep it simple and legible.

## Landmines — DO NOT TOUCH

1. **Do not modify `OratorEngine.swift`.** `currentVoice` and `speed` are already public settable — just set them. Touch no other engine state.
2. **Do not touch** `HotkeyManager.swift`, `TextChunker.swift`, `Pronunciations.swift`, `ReadableText.swift`, or the build scripts.
3. Only `AppDelegate.swift` + new `AppVoiceProfiles.swift`.
4. **Do not overwrite the `"voice"` / `"speed"` UserDefaults keys** from the per-app path. Those are the global default, owned by the existing Voice/Speed menu actions.
5. No third-party dependencies. Foundation + AppKit only.
6. Swift 6.2 strict concurrency ON; `AppDelegate` is `@MainActor`. Follow the existing `@unchecked Sendable` + `NSLock` pattern for the profiles store.

## Build & verify

- Build via `./scripts/build-app.sh` (xcodebuild; NOT `swift build`).
- Confirm it compiles. Do not sign, notarize, commit, or release — leave changes in the working tree.
- Report files changed; paste `AppVoiceProfiles.swift`, the `toggleSpeech` diff, and the new menu items.

## Out of scope

- Per-app pronunciation dictionaries
- Auto-detecting app category
- Editing a profile's voice inline in the table (use the "Use current voice for…" flow)
