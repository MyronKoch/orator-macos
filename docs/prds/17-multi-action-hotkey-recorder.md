# PRD 17: Multi-Action Hotkey Recorder

## Goal

The app now has three global hotkey actions (HotkeyManager's `HotkeyAction`): **speak** (default ⌥'), **pause** (⌥P), **queue** (⌥Q). The recorder window only handles speak. Replace it with a single "Keyboard Shortcuts" window where each action can be re-recorded and reset independently, with saved chords restored at launch.

## What exists (read first)

- `Sources/Orator/HotkeyManager.swift` (READ ONLY except calling its API): `HotkeyAction` enum, `reconfigure(_ action:keyCode:modifiers:)` (nil keyCode disables), `binding(for:)`, plus legacy `reconfigure(keyCode:modifiers:)`/`reconfigurePause` shims you should stop using.
- `Sources/Orator/AppDelegate.swift`, "MARK: - Hotkey recorder window": the current single-action recorder (window construction, `beginRecordingHotkey`, `recordHotkey(from:)`, `isStandaloneModifierKey`, `resetHotkeyToDefault`, local event monitor, `Pref.hotkeyKeyCode/hotkeyModifiers/hotkeyDisplay`, `savedHotkey`, and the recorder-related stored properties). Also `installKeyMonitor` where saved bindings are applied at launch, and the menu item that opens the recorder.

## Deliverables

**NEW `Sources/Orator/HotkeyRecorderWindow.swift`** - `HotkeyRecorderWindowController` (pure AppKit, patterns matching the other windows):

- Window "Keyboard Shortcuts", three rows: "Speak selection", "Pause / Resume", "Add selection to Queue". Each row: action name, current chord (e.g. "⌥Q"), **Record** button, **Reset** button.
- Recording: local `keyDown` monitor; ignore standalone modifier presses; require at least one of ⌘⌥⌃⇧; **Escape cancels recording**; only one action can be recording at a time (other Record buttons disable).
- **Conflict rejection:** a chord already bound to another action is refused with inline feedback ("Already used by Speak") and recording continues.
- **Forbidden chord:** any chord using Return (keyCode 36) is rejected with "Return-based shortcuts interfere with typing." This is a hard product constraint (the Option+Return default was removed in v1.1.1 for cause); never allow it for any action.
- On successful record: persist, call `hotkeyManager.reconfigure(action, ...)`, update the row label.
- Reset: restore that action's default (speak ⌥'/39, pause ⌥P/35, queue ⌥Q/12), clear its persisted override.

**EDIT `Sources/Orator/AppDelegate.swift`** (bounded):

- Delete the inline recorder code and its stored properties; the menu item (retitle to "Keyboard Shortcuts…") opens the new controller (lazily created, reused).
- Persistence keys: speak keeps the existing `hotkeyKeyCode`/`hotkeyModifiers`/`hotkeyDisplay` (backward compatible with users' saved shortcuts); add `hotkeyPauseKeyCode`/`hotkeyPauseModifiers`/`hotkeyPauseDisplay` and `hotkeyQueueKeyCode`/`hotkeyQueueModifiers`/`hotkeyQueueDisplay`.
- `installKeyMonitor` applies ALL saved bindings via `reconfigure(_:keyCode:modifiers:)` at launch.
- Nice-to-have (do it if simple): the "Pause Speaking"/"Resume Speaking" menu item title appends the current chord display, e.g. "Pause Speaking (⌥P)".

## Landmines - DO NOT TOUCH

- `HotkeyManager.swift`: call `reconfigure`/`binding(for:)` only; do not modify the file. Never register Return (36) in any form; never re-add an Option+Return default.
- `OratorEngine.swift`, `SpeechTimeline.swift`, `ReaderSession.swift`, `ReaderWindow.swift`, `TextChunker.swift`, `ReadableText.swift`, `Pronunciations.swift`, `Info.plist`, `Package.swift`, `scripts/`: untouched.
- No SwiftUI, no dependencies, no new actions (exactly the three in `HotkeyAction`).
- Do not break the existing saved speak shortcut of current users (legacy pref keys must keep working).

## Verification

No xcodebuild in your sandbox; type-check what you can. Self-review: monitor teardown on window close and cancel, one-recording-at-a-time invariant, conflict check against the OTHER actions' current (possibly just-changed) chords, Return rejection, legacy speak prefs still honored. Maintainer builds and runs the synthetic-keystroke regression for all three actions plus a recorded custom chord.

## Acceptance criteria

1. Window shows all three actions with current chords; record and reset work per action, applied immediately (no relaunch).
2. Recorded chords survive relaunch; legacy saved speak shortcuts still load.
3. Conflicting chords and any Return-based chord are refused with clear feedback.
4. Escape cancels a recording; closing the window mid-recording cleans up the monitor.
5. Default chords (⌥' / ⌥P / ⌥Q) all still fire after the refactor.
