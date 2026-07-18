# PRD 20: Rebuild settings tabs as native content (stop reparenting window views)

## The bug (root-caused)

In the Orator window (`Sources/Orator/OratorWindow.swift`), the **Dashboard** tab renders correctly but **Voices, Pronunciations, Shortcuts, General** render BLANK. Confirmed with real mouse clicks, in the current build.

**Root cause:** those four tabs get their content by taking a view that was built as a *hidden NSWindow's contentView* and **reparenting** it into the tab (`embeddedContentView()` on the editors → `SettingsScrollContainerView`). That reparented subtree does not draw in its new host. The Dashboard works precisely because `DashboardViewController` builds its view **fresh in code** and never reparents. A previous fix attempt (a flipped `SettingsScrollContainerView`) did NOT resolve it — **do not try to make reparenting work. Eliminate it.**

## The fix (non-negotiable architecture)

Every settings tab must build its **own fresh native content in code**, exactly like `DashboardViewController` does — fresh `NSView`s/`NSTableView`s/controls created in the tab's `loadView`, bound to the **same shared stores**. **No tab may reparent a view that belonged to a window.** Remove the `embeddedContentView()` / `SettingsScrollContainerView`-reparenting path for these tabs.

The three standalone editor windows still exist and are still opened elsewhere (`pronunciationsEditor?.show()` ~AppDelegate line 826, `appVoiceProfilesEditor?.show()` ~line 868) — **keep them working**. The tab and the window must each own a **separate, freshly-built** content view instance. Do not share one view instance between a window and a tab.

### Shared-store binding (reuse logic, not views)
- **Pronunciations tab:** a fresh `NSTableView` (Word / Say-it-like columns) + Add/Remove, all CRUD against `Pronunciations.shared` (add/remove/list). Same behavior as the standalone editor.
- **Shortcuts tab:** a fresh three-row recorder (Speak / Pause / Queue) with Record + Reset per row, one-recording-at-a-time, Escape cancels, conflict rejection, and the hard Return-chord rejection — driving the SAME `HotkeyManager` (`reconfigure(_:keyCode:modifiers:)` / `binding(for:)`) and the same persisted pref keys. Reuse the existing recorder logic by refactoring it into a reusable view (see below), never by reparenting.
- **Voices tab:** fresh voice popup + speed popup + preview (same engine/pref writes as today) + a fresh per-app-profiles table bound to `AppVoiceProfiles` (add/remove/preview rows).
- **General tab:** Start at Login, Remember my reading, Continuous reading, Clear history, Clear stats (confirm), recent-reads list, About/version — all reusing the existing prefs/stores.

### How to reuse editor logic without reparenting
Refactor each editor (`PronunciationsEditor`, `AppVoiceProfilesEditor`, `HotkeyRecorderWindowController`) so its content-building is a method that **constructs and returns a brand-new content view each call** (fresh table/controls), with the editor object acting as the `NSTableViewDataSource`/`delegate` for whichever table it built (the data-source methods already receive the `tableView`, so one store-backed editor can serve multiple fresh tables). The standalone window calls it once; the tab calls it again to get its own instance. `reload()`/`refresh()` must update every live view the editor vended. If sharing one editor object across two tables is awkward for the recorder's per-row recording state, give the tab its **own** editor/recorder instance bound to the same `HotkeyManager` and prefs.

## Files
- **EDIT** `Sources/Orator/OratorWindow.swift` — the tab view controllers build fresh content (like `DashboardViewController`); delete the reparenting (`SettingsScrollContainerView` hosting of vended window views, `embeddedContentView()` usage). A simple fresh `NSScrollView` + non-flipped documentView with content pinned and a bottom/height that makes it scroll (copy the Dashboard's working scroll pattern exactly).
- **EDIT** `Sources/Orator/AppDelegate.swift` — refactor the editors to vend fresh content views (not window-bound); keep the standalone windows working.
- **EDIT** `Sources/Orator/HotkeyRecorderWindow.swift` — if needed, expose a reusable fresh recorder content view.

## Landmines — DO NOT TOUCH
- `ReadingStats.swift`, `OratorEngine.swift`, `SpeechTimeline.swift`, `TextChunker.swift`, `Info.plist`, `Package.swift`, `scripts/`, `DashboardView.swift` (Dashboard works — leave it; only copy its scroll pattern).
- Do NOT change what any control does or which store/pref it writes. Do NOT change the menu, the teaser, hotkey behavior, or add a Return chord.
- Keep the standalone editor windows (`.show()`) fully working.
- No SwiftUI, no dependencies. Semantic colors only (light + dark).

## Verification
You cannot run xcodebuild. Type-check what you can. Self-review each of the 5 tabs: it builds a fresh content view in code, binds to the right shared store, and nothing is a reparented window contentView. Copy the Dashboard's exact scroll/documentView pattern so the content shows top-first and scrolls.

**The maintainer will screenshot EVERY tab.** A tab that renders blank is a failure. Summarize the root cause you removed and every file changed.

## Acceptance criteria
1. All five tabs render their content (light + dark). None blank.
2. Pronunciations CRUD, the three-action recorder (with conflict + Return rejection), voice/speed/preview, per-app profiles, and General toggles all work and write the same prefs/stores as before.
3. The standalone editor windows still open and work.
4. No reparented-window-content views remain in the tab path.
