# PRD 08 — Clean up preview temp on quit

**Status:** ready. Tiny.
**Scope:** `AppDelegate.swift` only. Zero core touch.

## Problem

The voice-preview feature writes a temp file `orator-preview.m4a`. It overwrites itself and the OS eventually cleans it, but we should remove it on quit for tidiness.

## Requirements (AppDelegate.swift)

1. Add a private helper `cleanupPreviewTempFile()` that stops `previewAudioPlayer` and deletes `FileManager.default.temporaryDirectory.appendingPathComponent("orator-preview.m4a")` if it exists (ignore errors).
2. Call it from the existing `quit()` action (before `NSApp.terminate`).
3. Also implement `func applicationWillTerminate(_:)` (NSApplicationDelegate) and call the same helper there, so quitting via ⌘Q / Force-quit-menu / logout also cleans up.

## Landmines — DO NOT TOUCH

- Only `AppDelegate.swift`. Do not touch any other file or the build scripts.
- Foundation + AppKit only.
- Swift 6.2 strict concurrency; `AppDelegate` is `@MainActor`.

## Build & verify

- `./scripts/build-app.sh` (xcodebuild; if sandbox-blocked, ensure it type-checks).
- Do not commit/sign/release. Report the diff.
