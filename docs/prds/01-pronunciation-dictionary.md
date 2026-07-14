# PRD 01 — Pronunciation Dictionary

**Status:** ready for implementation
**Scope:** small, isolated. One new file, edits to two existing files, one new settings window.
**Risk to core:** none if the rules below are followed.

## Problem

Kokoro mispronounces some names, acronyms, and domain terms (e.g. "Koch", "MLX", "nginx"). Users need a way to correct pronunciation without any knowledge of phonetics.

## Solution

A user-editable dictionary of plain-text substitutions applied to the text **before** it is synthesized. Keys are matched case-insensitively as whole words; values are the "respelling" that Kokoro pronounces correctly.

Example entries:
- `Koch` → `Coke`
- `MLX` → `em ell ex`
- `nginx` → `engine ex`

This is text preprocessing only. It does not touch the audio pipeline, the model, or the voice embeddings.

## Requirements

### 1. Substitution engine

Create `Sources/Orator/Pronunciations.swift` with a `Pronunciations` type that:
- Loads/saves a `[String: String]` map from `UserDefaults.standard` under the key `"pronunciations"` (store as a JSON-encoded `Data`, or a `[String:String]` dictionary directly — UserDefaults supports the latter).
- Exposes `func apply(to text: String) -> String` that replaces each dictionary key with its value, matching **whole words, case-insensitively**, preserving surrounding punctuation and whitespace. Use word-boundary matching (`\b` regex or equivalent), not naive substring replacement — substring replacement would corrupt words that contain a key as a fragment.
- Exposes `var entries: [(key: String, value: String)]` (sorted by key) plus `add(key:value:)`, `remove(key:)`, and is safe to read from the synthesis thread.

### 2. Integration point

In `Sources/Orator/TextChunker.swift`, apply the substitution **inside `chunk(_:)`, immediately after the `normalize(text)` call and before sentence splitting**. Do not change any other part of TextChunker. Do not change `OratorEngine` at all.

The substitution must be applied to the full normalized text once, before chunking, so multi-word replacements are not split across chunks.

### 3. Settings UI

Add a menu item **"Pronunciations…"** to the menu built in `AppDelegate.rebuildMenu()` (place it in the settings area, near the Voice/Speed items). Clicking it opens a small non-modal window with:
- A two-column editable list (Word → Say it like) of current entries
- Add and Remove buttons
- Changes persist immediately via the `Pronunciations` type

Match the existing onboarding window's construction style (programmatic AppKit `NSWindow` + `NSStackView`, no storyboards/XIBs). Keep it simple and legible; this is for non-technical users.

### 4. Seed defaults

Ship a small starter dictionary so the feature demonstrates itself on first run (only if the user has no saved entries yet): include `MLX → em ell ex`, `Kokoro → koh koh roh`, `macOS → mac oh ess`.

## Landmines — DO NOT TOUCH

These are hard-won constraints. Violating them silently breaks the shipped app.

1. **Do not modify `OratorEngine.swift`.** In particular, never touch the `generation`, `lock`, `scheduledBuffers`, `synthesisDone`, or `speaking` state, or the `speak()`/`stop()`/`schedule()` methods. That is the concurrency core and it is finished.
2. **Do not touch the voice-key lookup or `voices.npz` handling.** The triple-suffix fallback in `speak()` exists for a reason.
3. **Do not change the hotkey layer** (`HotkeyManager.swift`) or the clipboard capture in `AppDelegate.captureSelectedText`.
4. **Do not change the build scripts** (`scripts/build-app.sh`, `scripts/make-dmg.sh`).
5. **Do not add third-party dependencies.** Foundation + AppKit only. No SPM packages.
6. **Swift 6.2 strict concurrency is on.** Any type captured across threads (the `Pronunciations` instance is read on the synthesis thread) must be `Sendable`-safe. The existing code uses `@unchecked Sendable` with an `NSLock` for shared mutable state — follow that pattern if needed.

## Build & verify

- Build only via `xcodebuild` per `scripts/build-app.sh` (NOT `swift build` — MLX Metal shaders require Xcode's build system).
- After implementing, confirm the project compiles: `./scripts/build-app.sh` (ad-hoc sign is fine for the dev build).
- Do not attempt to sign, notarize, or release. Leave that to the maintainer.
- Do not commit. Leave changes in the working tree for review.

## Out of scope

- Phoneme/IPA-level control (that is a separate future PRD)
- Import/export of dictionaries
- Regex or pattern entries (whole-word plain text only for v1)
