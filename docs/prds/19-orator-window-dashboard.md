# PRD 19: The Orator Window — Dashboard + unified settings + menu cockpit

## Goal

Replace the settings-stuffed menu-bar dropdown with (a) a real tabbed **Orator** window whose opening tab is a **Dashboard** of local reading stats, and (b) a slim menu "cockpit" carrying a **live stats teaser**. Motivating, streak-forward stats. All local, all AppKit, nothing leaves the Mac.

The stats **engine already exists** (maintainer). This PRD is UI + menu only.

## What the engine already provides (DO NOT MODIFY)

`Sources/Orator/ReadingStats.swift` and `AppDelegate`:

- `AppDelegate.statsSnapshot: ReadingStatsSnapshot` — a value snapshot for the UI. Also `AppDelegate.reading: ReadingStats` for the goal setter / clear.
- `ReadingStatsSnapshot` fields: `lifetimeWords`, `lifetimeSeconds`, `totalReads`, `castReads`, `wordsToday`, `currentStreakDays`, `bestStreakDays`, `weeklyGoalWords`, `wordsThisWeek`, `week: [DayPoint]` (7 points oldest→today; each `date`, `weekdayInitial`, `words`, `isToday`), `topSources: [Ranked]` / `topVoices: [Ranked]` (each `name`, `words`, `fraction`), `longest: Longest?` (`title`, `words`, `seconds`, `voice`), computed `averageWordsPerRead`, `weeklyGoalFraction`.
- `ReadingStats.weeklyGoalWords` (get/set, persisted) and `ReadingStats.clear()`.
- Recording is already wired at every read; you only READ the snapshot.

Existing stores you REUSE for the settings tabs (do not reimplement their logic): `Pronunciations.shared`, `AppVoiceProfiles` (via `AppDelegate`'s existing per-app logic), `HotkeyManager` (via the existing recorder), `engine.voiceNames` / `engine.currentVoice` / `engine.speed`.

## Files

- **NEW** `Sources/Orator/OratorWindow.swift` — `OratorWindowController`: one `NSWindow`, a left sidebar (or `NSToolbar`) selecting tabs, hosting tab view controllers. `func show(tab:)`.
- **NEW** `Sources/Orator/DashboardView.swift` — the Dashboard tab content (an `NSView`/controller) that renders a `ReadingStatsSnapshot`, plus a small custom bar-chart view and the weekly-goal control.
- **NEW** `Sources/Orator/MenuStatsTeaser.swift` — the custom `NSView` used as an `NSMenuItem.view` for the live teaser.
- **EDIT** `Sources/Orator/AppDelegate.swift` — build the Orator window lazily; add menu items **Dashboard…** (⌘D) and **Orator Settings…** (⌘,) that open it at the right tab; insert the teaser item; move the migrated settings out of the menu (see Menu section). Keep a `private var oratorWindowController: OratorWindowController?`.

Pure AppKit. No SwiftUI, no dependencies.

## The Orator window — tabs

Sidebar tabs, in order: **Dashboard · Voices · Pronunciations · Shortcuts · General**. Window ~720×560, `setFrameAutosaveName("OratorWindow")`, `isReleasedWhenClosed = false`, reused instance. `LSUIElement` app → activate + makeKeyAndOrderFront on open. Semantic colors only (light/dark automatic).

### Dashboard tab (the flagship — build this richest)
Render `statsSnapshot`. Layout follows the approved mockup:
- **Hero:** big `lifetimeWords` (grouping-formatted) + caption "words read aloud"; secondary tiles for **hours listened** (`lifetimeSeconds/3600`, 1 dp) and **streak** (`currentStreakDays` with "best `bestStreakDays`"). Streak is the emotional centerpiece — make it prominent (accent color, e.g. controlAccentColor).
- **Weekly goal:** a progress bar/ring showing `weeklyGoalFraction` with "`wordsThisWeek` / `weeklyGoalWords` this week", and an **editable goal** (stepper or small field) that writes `AppDelegate.reading.weeklyGoalWords` and refreshes.
- **This week:** a 7-column bar chart from `week` (label each `weekdayInitial`, highlight `isToday` in the coral/accent, show the value). Custom `NSView` drawing bars, or constrained subviews — give it care (rounded caps, faint baseline).
- **Where you read** (`topSources`) and **Voices you pick** (`topVoices`): labeled rows with a proportional fill bar and a percent (`fraction`). Map voice keys to friendly names using the app's existing `displayName(for:)` if practical, else the raw name.
- **Longest read** + **reads/avg/cast** summary tiles (`longest`, `totalReads`, `averageWordsPerRead`, `castReads`).
- Refresh the snapshot in `viewWillAppear`/when the window shows and after a goal edit. Numbers use `tabular` figures where they align.

### Voices tab
Voice picker (all `engine.voiceNames`, grouped by region/gender prefix a/b + f/m, current selected), a **speed** control (the existing `speedOptions`), a **Preview** button per voice or a single preview of the selected voice (reuse the app's existing preview path), and **per-app voices** management (reuse the existing AppVoiceProfiles behavior — list current profiles, add/remove, per-row preview). Selecting a voice/speed updates `engine` + persists exactly as the current menu does. **Do NOT add an auto-cast control here** (that setting lives on a separate branch; leave it out).

### Pronunciations tab
Host the existing pronunciation editing over `Pronunciations.shared` (reuse the current `PronunciationsEditor` logic — refactor it to vend a content `NSView` the tab embeds, or re-present its table within the tab). Add/edit/delete rows must keep working.

### Shortcuts tab
Host the existing three-action recorder (speak/pause/queue) — reuse `HotkeyRecorderWindowController`'s row/record/reset/conflict logic by vending its content view into the tab. Do not change hotkey behavior or add chords; never allow Return chords.

### General tab
Toggles + actions, reusing existing prefs/logic: **Start at Login**, **Remember my reading** (the existing history/stats switch), **Continuous reading**, **Clear reading history**, **Clear stats…** (calls `reading.clear()`, confirm first), recent-reads list (the History submenu's content moves here), and an **About** line (app name, version from the bundle, "100% local").

> Migration approach: for the complex existing editors (Pronunciations, Shortcuts, Per-App), prefer refactoring each to expose a `contentView`/`makeContentView()` that BOTH the old standalone window and the new tab can host, so no behavior is duplicated. If a standalone window becomes redundant, the menu simply stops opening it.

## The menu — slim cockpit

Rebuild `rebuildMenu()` to:
1. **Header:** bust/name + a state line ("Reading" / "Paused" / idle) and, when speaking, a dim "now reading" title line (reuse whatever current text is available; a short prefix is fine).
2. **Quick actions:** Read a File…, Speak Clipboard (⌥'), Open Reader…, Pause/Resume (contextual), Stop.
3. **Queue ▸** and **Export ▸** — keep as today.
4. **Live teaser** (a `MenuStatsTeaser` view item): a 7-point sparkline from `statsSnapshot.week`, "`wordsToday` words today", and "`currentStreakDays`-day streak". Clicking it opens the Dashboard and closes the menu. Hover highlight like a normal item.
5. **Dashboard…** (⌘D) and **Orator Settings…** (⌘,) — open the window at Dashboard / Voices.
6. **Quit Orator** (⌘Q).

**Remove from the menu** (now in the window): Voice ▸, Speed ▸, Pronunciations…, Per-App Voices…, Keyboard Shortcuts…, Speak Test Sentence, Start at Login, History ▸. The menu should drop from ~18 top-level items to ~10.

Rebuild the menu (so the teaser refreshes) on the existing speech notifications, and after stats-affecting actions. The teaser must be cheap (one `statsSnapshot` read).

## Landmines — DO NOT TOUCH

- `ReadingStats.swift`, `OratorEngine.swift`, `SpeechTimeline.swift`, `HotkeyManager.swift`, `TextChunker.swift`, `ReadableText.swift`, `SpeechSegment.swift` (if present): DO NOT MODIFY. Read the snapshot; don't change the engine, timeline, hotkeys, or chunker.
- Do not change speech, queue, Reader, capture, or per-app-voice *behavior* — you are relocating controls, not re-plumbing them.
- No SwiftUI, no dependencies, no `Info.plist`/`Package.swift`/`scripts/` changes. Never add hotkeys; never a Return chord.
- Do not reference an "auto-cast" preference — it does not exist on this branch.
- Semantic colors only (no hardcoded light/dark). Respect reduced-motion if you animate anything (prefer not to).

## Verification

No xcodebuild in your sandbox; type-check what you can and self-review: the window opens/reuses cleanly; every migrated control still writes the same pref/store as before; the teaser reads one snapshot and opens the Dashboard; `weeklyGoalWords` round-trips; Clear stats confirms then empties. The maintainer builds, runs, and screenshots the Dashboard + menu.

## Acceptance criteria

1. Menu shows the live teaser (sparkline + words-today + streak) and opens the Dashboard on click; menu is visibly slimmer (~10 items).
2. Dashboard renders all snapshot fields with the streak prominent; editing the weekly goal updates the ring and persists.
3. Voices / Pronunciations / Shortcuts / General tabs work with parity to the old menu/editors (voice+speed+per-app, pronunciation CRUD, three-action recorder, start-at-login/remember/continuous/clear).
4. Nothing that worked before is lost; no speech/queue/Reader regressions.
5. Clean light and dark appearance.
