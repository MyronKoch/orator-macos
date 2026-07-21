# PRD 22: Expose "Dramatized reading" on three surfaces (tab, menu, hotkey)

## Context
Auto-casting (per-speaker dialogue voices) already works end to end: `DialogueCaster`,
`OratorEngine.speak(segments:)`, `SpeechTimeline.speak(segments:)`, and the `autoCast`
UserDefaults key all exist and are wired. The **engine is done — do not touch it.** This PRD
only adds/repairs the **user-facing controls** for that existing setting and gives it a
bindable hotkey.

**User-facing name is "Dramatize" / "Dramatized reading"** (the word "cast" collides with
Chromecast). **Keep all INTERNAL names as-is** — the `autoCast` pref key and the
`DialogueCaster` class do NOT get renamed (avoids a pref migration). Only the strings a user
sees change.

## Single source of truth + sync contract
The setting lives in `defaults.bool(forKey: Pref.autoCast)` (absent key = false = **off by
default**, which is the desired default — do NOT register a `true` default). Three surfaces
read/write it and must stay in sync:

1. Add an AppDelegate method `setAutoCast(_ enabled: Bool)` that: writes the pref, calls
   `rebuildMenu()`, and posts `NotificationCenter.default.post(name: .oratorAutoCastChanged, object: nil)`.
   Define `extension Notification.Name { static let oratorAutoCastChanged = Notification.Name("OratorAutoCastChanged") }`.
2. Refactor the existing `toggleAutoCast()` to call `setAutoCast(!defaults.bool(forKey: Pref.autoCast))`.
3. Every surface writes via `setAutoCast(...)`/`toggleAutoCast()` and reflects current state by
   reading the pref (menu rebuilds each open; the tab observes `.oratorAutoCastChanged`).

## Surface 1 — Voices tab checkbox (`OratorWindow.swift`, `VoicesSettingsViewController` ~line 387)
- Add, near the TOP of the Voices tab content, an `NSButton(checkboxWithTitle: "Dramatize dialogue", ...)`
  plus a secondary-color subtitle label: **"Quoted speech is read by a different voice per speaker. Off by default."**
- Initial state from `defaults.bool(forKey: Pref.autoCast)`.
- On toggle: `appDelegate.setAutoCast(sender.state == .on)`.
- Observe `.oratorAutoCastChanged` (add/remove observer in the controller's lifecycle) and update
  the checkbox state so menu/hotkey toggles reflect here live. Update `refresh()` to re-sync state too.
- **LANDMINE:** add every view to its superview BEFORE activating its constraints (an activation
  before `addSubview` throws "no common ancestor" and blanks the whole tab — this exact bug was
  fixed once already; do not reintroduce it).

## Surface 2 — Menu item (`AppDelegate.swift`, `rebuildMenu()`)
- Re-add a **checkable** item titled **"Dramatized reading"** with `action: #selector(toggleAutoCast)`,
  `target = self`, and `state = defaults.bool(forKey: Pref.autoCast) ? .on : .off`.
- Placement: in the reading-controls region — after the Export separator (~line 771, `menu.addItem(.separator())`)
  and BEFORE the `MenuStatsTeaser` block. Give it its own separator if it reads cleanly.
- (It previously lived in a submenu block that PR #16 retired; this restores it in the new slim menu.)

## Surface 3 — Hotkey: add a 4th bindable action `dramatize`
The recorder is data-driven (`for action in HotkeyAction.allCases`), so a 4th row appears
automatically once the enum + preference keys exist. Touch EVERY exhaustive switch or it won't compile.

### `HotkeyManager.swift`
- `enum HotkeyAction` (~line 23): add `case dramatize` after `.queue`.
- `carbonID` (~line 28): add `case .dramatize: return 4` (unique; 1/2/3 are taken).
- Default `bindings` dict (~line 65): add `.dramatize: Binding(keyCode: nil, modifiers: [.option])`.
  **`keyCode: nil` = unbound/disabled by default** (the desired default — no key assigned, zero
  collision risk; the user opts in via the recorder). No Carbon registration happens for a nil keyCode.

### `HotkeyRecorderWindow.swift` — handle an UNBOUND action (the fiddly part)
The `Chord` struct has a non-optional `keyCode`, and `chords` is `[HotkeyAction: Chord]` where
absence must now mean "unbound / Not set". Make these changes:
- `defaultChord(for:)` (~line 423): change return type to `Chord?`; return `nil` for `.dramatize`,
  the existing real chords for `.speak/.pause/.queue`. Update its one caller `defaultChordDisplay`
  (line ~420) to handle nil (e.g. return "Not set").
- `loadChords()` (~line 60) and any place that does `persistedChord(for:) ?? defaultChord(for:)`:
  when both are nil, leave `chords[action]` ABSENT (do not insert). A persisted chord still wins if present.
- Row display: when `chords[action] == nil`, the chordLabel shows **"Not set"** in
  `.secondaryLabelColor`. Recording a chord assigns it; **Reset** on the dramatize row clears it
  back to unbound (remove from `chords`, clear the three prefs, and call
  `hotkeyManager?.reconfigure(.dramatize, keyCode: nil, modifiers: [.option])`).
- `rowTitle(for:)` (~line 434): add `case .dramatize: return "Dramatize dialogue"`.
- `conflictName(for:)` (~line 441): add `case .dramatize: return "Dramatize"`.
- Keep the existing **Return-chord rejection** and **conflict detection** applying to this row too
  (they already loop `allCases`, so verify they include it).

### `AppDelegate.swift`
- `Pref` struct (~line 49): add `hotkeyDramatizeKeyCode`, `hotkeyDramatizeModifiers`, `hotkeyDramatizeDisplay`.
- `hotkeyPreferenceKeys` (~line 223): add `.dramatize: .init(keyCode: Pref.hotkeyDramatizeKeyCode, modifiers: Pref.hotkeyDramatizeModifiers, display: Pref.hotkeyDramatizeDisplay)`.
- `HotkeyManager` `onAction` closure (~line 202): add `case .dramatize: self?.toggleAutoCast()`.
- Launch restore: wherever saved bindings are restored on startup, restore `.dramatize` too **only
  if** a saved binding exists (default stays unbound). If the existing restore already loops
  `allCases`, nothing to add; if it's per-action, add the dramatize case.

## Landmines — DO NOT TOUCH / DO NOT BREAK
- **Do NOT touch the OratorEngine concurrency core** (`generation`/`lock`/`scheduledBuffers`/
  `synthesisDone`/`speaking`, `play(_:)`, `schedule(samples:)`) or `DialogueCaster` /
  `speak(segments:)` — they already work. This PRD is controls only.
- **NEVER register Return (keyCode 36) or any Return-based chord** as a default or accept one in
  the recorder. The existing guard must keep working for the new row.
- **Keep the internal `autoCast` pref key and `DialogueCaster` name** — no rename, no migration.
- **Default stays OFF and UNBOUND** — do not register `autoCast=true`, do not give `.dramatize` a
  default keyCode.
- Semantic colors only (light + dark). No SwiftUI, no new dependencies.
- addSubview BEFORE constraint activation (blank-tab "no common ancestor" lesson).

## Verification (you cannot run xcodebuild — the maintainer will)
Type-check what you can. Self-review that: every `HotkeyAction` switch is exhaustive
(`carbonID`, `defaultChord`, `rowTitle`, `conflictName`, the `onAction` switch); the unbound
"Not set" path is coherent (display, record, reset); all three surfaces read/write the same
`autoCast` pref and stay in sync via `.oratorAutoCastChanged`; and the default is off + unbound.
The maintainer builds, signs, and runs a synthetic-keystroke functional test on the hotkey.

## Acceptance criteria
1. **Voices tab** shows a "Dramatize dialogue" checkbox (OFF by default) + the subtitle; toggling
   it enables per-speaker dialogue voices.
2. **Menu** shows a checkable "Dramatized reading" item reflecting and toggling the same setting.
3. **Shortcuts tab** shows a 4th "Dramatize dialogue" row: **"Not set"/unbound by default**,
   recordable and resettable (reset → unbound), with conflict + Return-chord rejection.
4. Toggling any one surface updates the other two (menu/tab/hotkey all in sync).
5. Default OFF; internal `autoCast` key unchanged; **no engine changes**; project builds clean.
