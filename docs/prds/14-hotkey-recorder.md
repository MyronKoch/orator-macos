# PRD 14 — Custom Hotkey Recorder

**Status:** ready.
**Scope:** `HotkeyManager.swift` (make the combo configurable) + `AppDelegate.swift` (recorder UI + persistence).
**Risk:** the `HotkeyManager` change is the app's fragile core — follow the design below exactly. The maintainer will review this diff with extra scrutiny.

## Goal

Let users record their own global shortcut instead of the fixed Option+'. A recorded shortcut **replaces** the default. Until one is recorded, the current default (Option+' plus Option+Return) keeps working.

---

## Part A — `HotkeyManager.swift`: make the combo configurable

### Design principle (LOW-RISK — follow exactly)

The NSEvent monitor and CGEvent tap match the key **inside their callbacks at event time**. If those callbacks read the combo from **instance variables** instead of the `static` constants, they automatically honor a new combo with **no teardown or re-install**. Only Carbon's `RegisterEventHotKey` binds the combo at registration time, so **only Carbon needs re-registration** when the combo changes. Do not tear down or re-create the NSEvent monitor or the CGEvent tap on reconfigure.

### Changes

1. Replace the `static let keyCode`/`altKeyCode` with instance state:
   ```swift
   private var keyCode: UInt16 = 39                    // default: apostrophe
   private var altKeyCode: UInt16? = 36                // default: Return (secondary); nil once a custom combo is set
   private var modifiers: NSEvent.ModifierFlags = [.option]   // canonical modifier set
   ```

2. Add modifier translation helpers:
   - `carbonModifiers` computed from `modifiers` (`.option`→`optionKey`, `.command`→`cmdKey`, `.control`→`controlKey`, `.shift`→`shiftKey`; OR them).
   - A match check for CGEvent flags: the event's `.flags` must contain the mapped required flags (`.option`→`.maskAlternate`, `.command`→`.maskCommand`, `.control`→`.maskControl`, `.shift`→`.maskShift`) and must NOT contain any modifier flag that isn't in `modifiers` (exact-match, as the current code does with its `!flags.contains(...)` guards).
   - A match check for NSEvent flags: `event.modifierFlags.intersection([.option,.command,.control,.shift]) == modifiers`.

3. Update the three paths:
   - **NSEvent monitor** callback: match `event.keyCode == keyCode` (or `== altKeyCode` when non-nil) AND the NSEvent modifier match above. Read the instance vars live.
   - **CGEvent tap** callback: match `keyCode == self.keyCode` (or altKeyCode when non-nil) AND the CGEvent flag match above. Read the instance vars live via the `manager` reference it already resolves.
   - **Carbon**: register using `carbonModifiers`. **Split handler-install from hotkey-register:** install the Carbon `InstallEventHandler` ONCE (it must not be installed twice), and put the `RegisterEventHotKey` in its own method `registerCarbonHotKey()` that first `UnregisterEventHotKey(carbonHotKeyRef)` if a ref exists, then registers with the current `keyCode` + `carbonModifiers`.

4. Add:
   ```swift
   func reconfigure(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
       self.keyCode = keyCode
       self.altKeyCode = nil          // custom combo drops the Return secondary
       self.modifiers = modifiers
       registerCarbonHotKey()          // ONLY Carbon re-registers; NS/CG read live vars
       log("hotkey reconfigured: keyCode=\(keyCode) modifiers=\(modifiers.rawValue)")
   }
   ```
   `installAll()` stays as the initial install (install Carbon handler once, then `registerCarbonHotKey()`, then NSEvent monitor, then event tap, then census).

5. Keep the debounce, the census, the logging, and the exact permission logic unchanged.

**Do not change** the dedupe/debounce, the tap creation options, or the permission requests. This is a parameterization, not a rewrite.

---

## Part B — `AppDelegate.swift`: recorder UI + persistence

1. **Persistence:** UserDefaults keys `"hotkeyKeyCode"` (Int), `"hotkeyModifiers"` (UInt, `NSEvent.ModifierFlags.rawValue`), `"hotkeyDisplay"` (String). If all present, treat as a custom combo.

2. **On launch, after `installKeyMonitor()`:** if a custom combo is saved, call `hotkeyManager?.reconfigure(keyCode:modifiers:)` with the saved values.

3. **Menu:** add **"Record Shortcut…"** (near the bottom, by Start at Login). It opens a small non-modal window (match the onboarding/pronunciation window style) with:
   - A label showing the current shortcut (the saved `"hotkeyDisplay"`, or "⌥ '" default).
   - A **"Record"** button. When clicked, it enters record mode: install a **local** `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` that captures the next keyDown. Require at least one of `.option/.command/.control/.shift`; ignore a press with no modifier (keep waiting) and ignore standalone modifier keys. On a valid combo: capture `event.keyCode` and `event.modifierFlags.intersection([.option,.command,.control,.shift])`; build a display string from the modifier symbols (⌘⌥⌃⇧) + `event.charactersIgnoringModifiers?.uppercased()` (fallback to the keycode number); save all three to UserDefaults; call `AppDelegate.shared`/self to `hotkeyManager?.reconfigure(...)`; update the label; remove the local monitor.
   - A **"Reset to Default"** button: remove the three UserDefaults keys, call `hotkeyManager?.reconfigure(keyCode: 39, modifiers: [.option])` (note: reset uses ' only; the Return secondary is a launch-time default, acceptable), update the label to "⌥ '".
   - A short helper line: "Press a key combination with at least one modifier (⌘ ⌥ ⌃ ⇧)."

4. Keep `Self.hotKeyLabel` usages working; the menu's existing "press ⌥ '" status text may stay as-is or read the saved display — either is fine, do not overcomplicate.

## Landmines — DO NOT TOUCH

1. Only `HotkeyManager.swift` and `AppDelegate.swift`. No other file, no build scripts.
2. In `HotkeyManager`, do NOT alter the debounce, permission requests, tap options, census, or logging. Follow Part A's "only Carbon re-registers" design — do not tear down/re-create the NSEvent monitor or CGEvent tap on reconfigure.
3. Do NOT install the Carbon `InstallEventHandler` more than once (double handlers = double fires).
4. Foundation + AppKit + Carbon only. Swift 6.2 strict concurrency; `AppDelegate` is `@MainActor`; `HotkeyManager` is `@unchecked Sendable`.
5. Do not break `toggleSpeech`, per-app voices, the queue, or any menu behavior.

## Build & verify

- `./scripts/build-app.sh` (xcodebuild; if sandbox-blocked, ensure it type-checks and say so).
- Do not commit/sign/release. Report the `HotkeyManager` diff in full (the maintainer reviews it closely) and the recorder UI additions.

## Out of scope

- Conflict detection with system shortcuts
- Multiple simultaneous custom hotkeys
- Recording mouse buttons
