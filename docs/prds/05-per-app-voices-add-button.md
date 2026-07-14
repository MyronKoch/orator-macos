# PRD 05 — Per-App Voices: Add-App button + editable rows

**Status:** ready for implementation
**Scope:** `AppDelegate.swift` only (the `AppVoiceProfilesEditor` class + its instantiation).
**Risk to core:** none. Uses the existing `AppVoiceProfiles` store API and `engine.voiceNames`.

## Problem

The "Per-App Voices" management window is currently a read-only viewer. When empty it shows a table with no way to act — the user has to know to go read from an app first, then use the menu bar. That is confusing (see user feedback). The window should let you **add an app and choose its voice/speed directly**.

## Solution

1. Add an **"Add App…"** button to the window. It lists currently-running regular apps; picking one creates a profile.
2. Make the **Voice** and **Speed** cells **editable** (pop-up buttons) so the user can set/adjust them right in the table.

No new store methods are needed — `AppVoiceProfiles` already has `set(bundleID:appName:voice:speed:)`, `remove(bundleID:)`, and `all`.

## Requirements (all in `AppDelegate.swift`)

### 1. Pass the voice list + speed options into the editor

`AppVoiceProfilesEditor` needs the available voices and speed choices. Update its initializer (and the `openPerAppVoices()` call site) to pass:
- `voiceNames: [String]` — from `engine?.voiceNames ?? []`
- the speed options already used by the Speed menu: `[0.8, 0.9, 1.0, 1.1, 1.25, 1.5]` (define once; reuse if a constant already exists)

### 2. "Add App…" button

Below the table, add an **"Add App…"** button. On click, present a picker of running apps:
- Source: `NSWorkspace.shared.runningApplications`, filtered to `activationPolicy == .regular`, having a non-nil `bundleIdentifier` and `localizedName`, excluding Orator itself (`Bundle.main.bundleIdentifier`) and any bundleID already in the table.
- Sort by localized name. Present as an `NSMenu` popped up from the button (show each app's name; the app icon via `NSRunningApplication.icon` is a nice-to-have, optional).
- On selection: create a profile via `profiles.set(bundleID:appName:voice:speed:)` using the **first available voice** (or `"af_heart"` if the list is empty) and speed `1.0` as initial values, then reload the table and select the new row. The user then adjusts Voice/Speed inline (below).

### 3. Editable Voice + Speed cells

Replace the read-only Voice and Speed cells with `NSPopUpButton`s:
- **Voice** pop-up: the `voiceNames` list; current selection reflects the row's saved voice. On change, call `profiles.set(...)` for that row's bundleID with the new voice (keep existing appName + speed).
- **Speed** pop-up: the speed options formatted like the menu (e.g. `"1.0x"`); on change, `profiles.set(...)` with the new speed (keep appName + voice).
- Use the target/action or a closure to persist immediately. Keep each pop-up bound to the correct row (tag the control with the row index, or resolve via `tableView.row(for:)`).

### 4. Keep

- The existing **Remove** button/column behavior.
- The caption text is fine; optionally soften it to mention the new "Add App…" button.
- The rebuild-menu callback the editor already invokes on changes.

## Landmines — DO NOT TOUCH

1. Modify **only `AppDelegate.swift`**. Do not change `AppVoiceProfiles.swift` (its API is sufficient) or any other file.
2. Do not touch `OratorEngine.swift`, `HotkeyManager.swift`, `TextChunker.swift`, `Pronunciations.swift`, `ReadableText.swift`, or the build scripts.
3. No third-party dependencies. Foundation + AppKit only.
4. Swift 6.2 strict concurrency ON; `AppDelegate` and the editor are `@MainActor`.
5. Do not overwrite the global `"voice"` / `"speed"` UserDefaults keys.

## Build & verify

- Build via `./scripts/build-app.sh` (xcodebuild; NOT `swift build`). If the sandbox blocks the build, ensure it type-checks and say so.
- Do not sign, notarize, commit, or release — leave changes in the working tree.
- Report the changes and paste the new "Add App…" handler + the editable Voice/Speed cell code.

## Out of scope

- Per-app pronunciation
- Searching/filtering the app list
- Assigning apps that aren't currently running (running-apps only for v1)
