# PRD 15: Reader Window with Karaoke Follow-Along Highlighting

## Goal

A dedicated reading window - the flagship demo feature. The full text is displayed in a clean, comfortable reading view; each word lights up in sync as it is spoken; the view auto-scrolls to keep the spoken word visible; clicking a sentence jumps playback there; pause/resume and sentence skip work from buttons and the keyboard.

## What the engine already provides (DO NOT MODIFY THE ENGINE)

The maintainer has already landed the timing surface in `OratorEngine.swift` and `SpeechTiming.swift`. Read both files first. You get:

- `engine.speak(chunks: [String]) throws -> Int` - speaks pre-chunked text, returns the **utterance ID** (or -1 for empty input). The existing `speak(_ text: String)` is unchanged.
- `engine.onChunkTiming: (@Sendable (ChunkTiming) -> Void)?` - set BEFORE calling `speak`. Called on the **main queue** as each chunk finishes synthesis.
- `ChunkTiming`: `utteranceID`, `chunkIndex` (zero-based within the utterance), `chunkCount`, `text` (exact chunk string), `offset` (utterance-absolute seconds where this chunk's audio begins), `duration`, `words: [WordTiming]`.
- `WordTiming`: `text`, `whitespace`, `start`/`end` - **chunk-relative** seconds; `nil` for punctuation tokens. Absolute time = `chunkTiming.offset + word.start`.
- `engine.playbackPosition: TimeInterval?` - seconds of audio played in the current utterance. Returns `nil` before first play, after stop, and possibly while paused - **hold the last non-nil value you observed**.
- `engine.pause()` / `engine.resume()`.
- Existing notifications: `.oratorSpeechStarted`, `.oratorSpeechFinished`.
- `TextChunker.chunk(_ text: String) -> [String]` - deterministic. The Reader chunks its document ONCE and passes array slices to `speak(chunks:)` for jumps, so chunk boundaries stay stable across seeks.

## Files

- **NEW** `Sources/Orator/ReaderSession.swift` - all model/timing/alignment logic, UI-free (unit-testable later).
- **NEW** `Sources/Orator/ReaderWindow.swift` - `ReaderWindowController` (window + text view + control bar).
- **EDIT** `Sources/Orator/AppDelegate.swift` - BOUNDED: one new menu item, one window-controller property, one open-reader action that reuses the existing `captureSelectedText(completion:)` (around line 249). Nothing else changes in this file.

## ReaderSession (the model)

Main-thread confined (`@MainActor`). Owns:

- `text: String` - the display document. Build it as `chunks.joined(separator: " ")` where `chunks = TextChunker.chunk(rawText)`. Record each chunk's character range in the display string as you join (exact by construction).
- `play(fromChunk i: Int)`:
  1. `engine.stop()`
  2. set `engine.onChunkTiming` (weak self, filter by utterance ID)
  3. `utteranceID = try engine.speak(chunks: Array(chunks[i...]))`
  4. record `baseChunkIndex = i` so callback indices map to global chunk indices: `global = baseChunkIndex + timing.chunkIndex`.
- **Word alignment** (the one subtle part). When a `ChunkTiming` arrives (after dropping mismatched `utteranceID`s), align its words to the display string with a **tolerant sequential scan** inside that chunk's character range:
  - keep a cursor starting at the chunk range's lowerBound
  - for each `WordTiming` with non-nil `start`: `displayText.range(of: word.text, options: [.literal], range: cursor..<chunkEnd)`; on hit, record `(charRange, absStart: offset + start, absEnd: offset + end)` and advance the cursor to `range.upperBound`; **on miss, skip the token silently** (no highlight for that word - never throw, never cascade).
  - Tolerance is REQUIRED: token text reconstructs Misaki-preprocessed text which can differ slightly from the chunk string (number expansion, alias substitution). A skipped word is fine; a crash is not.
- Sorted array of aligned word entries; binary search by time for "word active at position `t`".
- Current-position tracking: a `Timer` at 1/30 s (scheduled in `.common` run-loop mode so it ticks during scrolling) reads `engine.playbackPosition ?? lastKnown`. Emit "active word changed" only when the word actually changes.
- State machine: `idle / playing / paused`. On `.oratorSpeechFinished`: if it ends our utterance, go idle and clear the highlight. On `.oratorSpeechStarted` for an utterance we did NOT start (user hit the global hotkey elsewhere - the engine is shared and a foreign utterance cancels ours): go idle, stop the timer, clear highlight. No crash, no fight.
- Cleanup: on window close, `engine.stop()` (Reader stop stops everything - document this in a comment), set `engine.onChunkTiming = nil`, invalidate the timer.

## ReaderWindowController (the view)

- `NSWindow`, title "Orator Reader", resizable, `setFrameAutosaveName("OratorReader")`, min size ~520x400, `isReleasedWhenClosed = false`, single reusable instance owned by AppDelegate (match the existing window patterns in AppDelegate - this app is **pure AppKit; do NOT introduce SwiftUI**).
- Because the app is `LSUIElement`, opening must `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront` (copy the existing windows' pattern).
- Content: non-editable, selectable `NSTextView` in an `NSScrollView`. Reading typography: system font ~16 pt, line-height multiple ~1.3-1.4, text container inset ~(24, 28). Use semantic colors only (`.labelColor`, `.textBackgroundColor`) so dark mode is automatic.
- Control bar (bottom, plain `NSView` with `NSButton`s using SF Symbols): Back (`backward.fill`), Play/Pause toggle (`play.fill`/`pause.fill`), Stop (`stop.fill`), Forward (`forward.fill`), and a right-aligned label "sentence i of n" once known, elapsed time before that.
- **Highlight rendering: `NSLayoutManager` temporary attributes ONLY.** `addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.35), forCharacterRange: activeWordRange)`, removing the previous word's attribute first. NEVER edit `textStorage` attributes per tick - that would relayout the whole document 30 times a second.
- **Auto-scroll:** when the active word's rect falls outside the visible rect inset by ~60 pt vertically, `scrollRangeToVisible`. Suppress auto-scroll for ~2 s after any user-initiated scroll (observe the scroll view's `NSScrollView.willStartLiveScrollNotification` / `didLiveScrollNotification`) - hysteresis so the user can browse while it plays.
- **Click-to-jump:** on click in the text view (override `mouseDown` in an `NSTextView` subclass, or use `characterIndexForInsertion(at:)`), map character index → chunk whose display range contains it → `session.play(fromChunk: that)`. Jump granularity is the **sentence/chunk**, not the word (a jump re-synthesizes from the chunk boundary; that is by design).
- Keyboard: Space = play/pause, Left/Right arrows = sentence skip, ⌘W closes (window close stops playback). Implement via `keyDown` in the window or text view subclass; do not add any global hotkeys.
- Sentence skip buttons: `play(fromChunk: current ± 1)`, clamped.
- Empty state: if opened with no text, show a centered secondary-label message "Select or copy text, then choose Open Reader again." (simple `NSTextField` overlay is fine).

## AppDelegate integration (bounded)

- New menu item **"Open Reader…"** placed immediately after "Speak Clipboard" in the existing menu-build function, enabled under the same conditions.
- Its action: `captureSelectedText { text in ... }` - if capture yields text, open the Reader with it; else fall back to `NSPasteboard.general.string(forType: .string)`; else open the Reader in its empty state.
- Keep a `private var readerWindowController: ReaderWindowController?`, create lazily, reuse thereafter (loading new text into the existing window replaces the document and stops current playback).

## Concurrency rules (Swift 6 strict mode - the package is swift-tools 6.2, default language mode)

- `ReaderSession` and `ReaderWindowController` are `@MainActor`.
- `engine.onChunkTiming` takes a `@Sendable` closure delivered on the main queue: inside it use `MainActor.assumeIsolated { ... }` to hop into your types (it is genuinely on main; this is the correct pattern, not `DispatchQueue.main.async`).
- `AppDelegate` is already `@MainActor` - follow its existing patterns.

## Landmines - DO NOT TOUCH

- **`OratorEngine.swift`: DO NOT MODIFY.** The timing surface you need is already there. If something seems missing, STOP and write a note in your summary instead of editing the engine.
- **`HotkeyManager.swift`: DO NOT MODIFY.** No new global hotkeys anywhere. NEVER add an Option+Return chord to anything.
- **`TextChunker.swift`, `ReadableText.swift`, `Pronunciations.swift`: DO NOT MODIFY.** Call `TextChunker.chunk` as-is.
- No SwiftUI, no new dependencies, no Package.swift changes.
- Do not rename, reorder, or restyle existing menu items; only insert the one new item.
- Do not touch `Info.plist`, scripts, or any other file not listed under Files.

## Verification

Your sandbox cannot run `xcodebuild` (MLX Metal shaders require it), so you cannot fully build. Type-check as far as your environment allows and review your own diff carefully for: retain cycles (timer → session → timer), temporary-attribute cleanup on stop, utterance-ID filtering, and the foreign-utterance reset path. The maintainer will build-verify with xcodebuild and run the functional test.

## Acceptance criteria

1. Menu "Open Reader…" opens the window with the captured selection (clipboard fallback; empty state otherwise).
2. Play speaks and words highlight in sync; punctuation never highlights; no crash on emoji, URLs, numbers, or code-ish text (alignment misses skip silently).
3. Auto-scroll keeps the active word visible; manual scrolling suppresses it for ~2 s.
4. Clicking a sentence restarts playback from that sentence; highlighting follows correctly (global chunk mapping right after a jump).
5. Space toggles pause/resume; arrows skip sentences; ⌘W closes and stops.
6. Triggering the global hotkey elsewhere while the Reader is playing resets the Reader to idle without a crash.
7. Closing the window stops playback and clears `onChunkTiming`.
