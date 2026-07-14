# PRD 13 — Menu Reorganization

**Status:** ready.
**Scope:** `AppDelegate.swift` `rebuildMenu()` only. Zero core touch, no behavior change.
**Risk:** none — pure reordering/grouping of existing menu items. All actions/selectors stay identical.

## Problem

The menu bar dropdown has grown to ~28 flat items with no grouping (export actions scattered, voice settings interleaved with queue and history). It needs logical grouping so users can find things.

## Solution

Regroup the **existing** items (same titles, same `#selector` actions, same enabled/contextual conditions) into a clear ordered structure with separators and a couple of new submenus. **Do not add, remove, or rename any action** — only reorganize. Do not change any handler.

## Target structure (top to bottom)

1. **"Orator"** disabled header (unchanged)
2. **Status line** + **"Grant Permission…"** when not trusted (unchanged conditions)
3. `separator`
4. **Content actions:**
   - "Read File…"
   - "Speak Clipboard"
   - "Stop Speaking"
5. `separator`
6. **"Queue"** submenu — keep the existing Queue submenu (count header, items, Play/Stop/Clear). **Move "Continuous Reading" into this submenu** (append after Clear Queue, with a separator before it). Also add **"Add Selection to Queue"** and **"Add Clipboard to Queue"** into the top of this submenu (they are currently top-level) — so all queue actions live together.
7. **"Export"** submenu (NEW) — move the three existing export items into it:
   - "Export Selection to Audio…"
   - "Export Clipboard to Audio…"
   - "Export File to Audio…"
8. **"History"** submenu (unchanged — keep as-is)
9. `separator`
10. **Voice settings:**
    - "Voice" submenu (unchanged)
    - "Speed" submenu (unchanged)
    - "Pronunciations…"
    - "Per-App Voices…"
    - "Use current voice for [app]" / "Clear voice for [app]" (unchanged contextual conditions — keep them here)
11. `separator`
12. **"Speak Test Sentence"** (diagnostic — keep, near the bottom)
13. `separator`
14. **"Start at Login"** (unchanged)
15. **"Quit Orator"** (unchanged)

## Rules

- Preserve every existing item's `action`/`target`/`representedObject`/`state`/enabled logic exactly. This is a move-only change.
- Keep all existing conditional visibility (e.g., "Grant Permission…" only when untrusted; "Use/Clear current voice for [app]" only when `lastReadApp` is set / a profile exists; queue Play/Stop/Clear conditions; History empty state). Just relocate them into the new grouping.
- The Queue, History, Voice, and Speed submenus already exist — reuse their construction; only move Continuous Reading + the two "Add … to Queue" items into the Queue submenu, and create the new Export submenu.
- No new UserDefaults, no new state, no new selectors.

## Landmines — DO NOT TOUCH

1. Only `AppDelegate.swift` `rebuildMenu()` (and, if strictly necessary, the immediately-related item-construction helpers already in AppDelegate). Change no other file.
2. Do not modify `OratorEngine.swift`, `HotkeyManager.swift`, `TextChunker.swift`, `ReadableText.swift`, `Pronunciations.swift`, `AppVoiceProfiles.swift`, `FileTextExtractor.swift`, `ReadingHistory.swift`, `OratorIntents.swift`, or the build scripts.
3. Do not change any `@objc` handler or its behavior — move-only.
4. Foundation + AppKit only. Swift 6.2 strict concurrency; `AppDelegate` is `@MainActor`.

## Build & verify

- `./scripts/build-app.sh` (xcodebuild; if sandbox-blocked, ensure it type-checks and say so).
- Do not commit/sign/release. Report the new `rebuildMenu()` structure.

## Out of scope

- Icons on menu items
- Renaming items
- Keyboard shortcuts for items
