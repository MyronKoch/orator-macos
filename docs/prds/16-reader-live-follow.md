# PRD 16: Reader Live-Follow (the bouncing ball on ANY utterance)

## The problem (real user feedback)

PRD 15 shipped the Reader as a standalone document player: it only karaokes utterances started from inside the window, and worse, opening it while Orator is speaking STOPS the live speech (`load` → `stop`). The user's actual mental model, which is the correct product:

> Highlight text anywhere → hotkey → Orator starts reading → open the Reader → watch the bouncing ball follow along on the text that is ALREADY being spoken.

The Reader must be a **lens on whatever Orator is currently reading**, no matter how the speech was started (hotkey, menu, queue, history, file, test sentence). It must NEVER stop live speech when opening.

## Architecture change

Today timing flows engine → ReaderSession, but only when the Reader itself started the utterance; hotkey speech discards its timings. Invert the ownership:

**NEW `Sources/Orator/SpeechTimeline.swift`** - an always-on, app-level recorder:

```swift
@MainActor
final class SpeechTimeline {
    struct Utterance {
        let id: Int                      // engine utteranceID
        let chunks: [String]             // the FULL document chunk list
        let baseIndex: Int               // global index where this utterance started
        var timings: [Int: ChunkTiming]  // keyed by GLOBAL chunk index
    }

    enum Event {
        case utteranceStarted            // new document or a jump within it
        case chunkTimed(globalIndex: Int)
        case utteranceEnded
    }

    private(set) var current: Utterance?
    var isActive: Bool                   // engine.isSpeaking, passthrough
    var onEvent: (@MainActor (Event) -> Void)?   // the Reader subscribes here

    init(engine: OratorEngine)           // registers engine.onChunkTiming ONCE, forever
    func speak(text: String) throws     // TextChunker.chunk + speak(chunks:from: 0)
    func speak(chunks: [String], from index: Int) throws
}
```

Rules:

- `init` sets `engine.onChunkTiming` exactly once. The closure (delivered on main, `@Sendable` - use `MainActor.assumeIsolated`) drops timings whose `utteranceID != current?.id`, maps `chunkIndex` to global (`baseIndex + chunkIndex`), stores, and emits `.chunkTimed`.
- `speak(chunks:from:)` mirrors what ReaderSession.play does today: `engine.stop()`, `engine.speak(chunks: Array(chunks[index...]))`, record `Utterance(id:chunks:baseIndex:)`, emit `.utteranceStarted`. A jump within the SAME chunk list keeps the document identity (the Reader can tell because `chunks` is unchanged - compare by identity or equality).
- Observe `.oratorSpeechFinished` (queue .main): if `current != nil` and `!engine.isSpeaking`, emit `.utteranceEnded` (keep `current` so an idle Reader still shows the last document).
- `AppDelegate` owns the single `SpeechTimeline` instance, created right after the engine loads.

**Route ALL speech through the timeline.** Replace every direct `engine.speak(text)` in `AppDelegate.swift` with `timeline.speak(text:)` - there are six call sites: `speakText` (~line 111), `toggleSpeech` (~245), `readHistoryEntry` (~746), `playNextInQueue` (~795), the read-file completion (~848), `speakTestSentence` (~976). Some currently hop through `DispatchQueue.global` before speaking; since `SpeechTimeline` is `@MainActor` and `engine.speak` is non-blocking (synthesis runs on the engine's own queue), replace the global-queue hop with a main-queue hop (`DispatchQueue.main.async` / `Task { @MainActor in }`). `TextChunker.chunk` for very large documents (read-a-file) may stay on a background queue, then hop to main to call `timeline.speak(chunks:from: 0)`.

After the change, `engine.speak` must have **zero call sites outside SpeechTimeline** - grep to confirm before you finish.

## ReaderSession rework

ReaderSession stops owning `engine.onChunkTiming` and becomes a **view of the timeline**:

- Init takes `(timeline: SpeechTimeline, engine: pause/resume/stop/playbackPosition access)`. Subscribe to `timeline.onEvent`.
- On `.utteranceStarted`: if `timeline.current` has a different chunk list than displayed → rebuild document (chunks joined with " ", chunk ranges, clear alignments) and notify the window to reload text; if same chunk list (a jump) → keep document, clear stale state, resume following. Either way state = `.playing`, start the 30 Hz timer.
- On `.chunkTimed(globalIndex)`: run the existing tolerant word alignment for that chunk (unchanged logic - the timing's words + the chunk's display range).
- On `.utteranceEnded`: idle, clear highlight, keep document and `currentChunkIndex`.
- **Hydration on open:** `syncFromTimeline()` - if `timeline.current` exists, build the document AND replay all stored `timings` through the alignment path, set state from `engine.isSpeaking`/`engine.isPaused`, start the timer if active. This is what makes opening mid-utterance show the ball already bouncing at the right word.
- `play(fromChunk:)` and `skip(by:)` now call `timeline.speak(chunks: fullChunks, from: i)` (full document list, so jumps keep document identity).
- `load(rawText:)` (the fallback path, see below) must NOT call `stop()` implicitly - loading a new document explicitly replaces it via `timeline.speak` only when the user presses Play.
- The old "foreign utterance" reset logic DISAPPEARS - there are no foreign utterances anymore; every utterance is a timeline event the Reader renders. Remove the `.oratorSpeechStarted` observer and `isStartingOwnUtterance` flag.
- Keep the paused/resumed observers (they sync the Play/Pause button with the global Option+P hotkey).

## Open Reader behavior (AppDelegate)

`openReader()` new logic:

1. If `timeline.current != nil` (speaking, paused, or finished-but-loaded) → open the window and `syncFromTimeline()`. **Do NOT capture selection, do NOT stop anything.**
2. Else (nothing ever spoken) → current behavior: capture selection → clipboard fallback → load as a passive document the user can Play.
3. While open, new utterances from anywhere replace the document live (via `.utteranceStarted`).

Update the empty-state message to: "Orator isn't reading anything. Select text and press your hotkey, or copy text and reopen the Reader."

## Files

- **NEW** `Sources/Orator/SpeechTimeline.swift`
- **EDIT** `Sources/Orator/ReaderSession.swift` - rework per above (alignment, binary search, timer, highlight callbacks all stay)
- **EDIT** `Sources/Orator/ReaderWindow.swift` - document-reload hook when the timeline replaces the document; everything else stays
- **EDIT** `Sources/Orator/AppDelegate.swift` - create timeline, route the six speak call sites, new `openReader()` logic

## Landmines - DO NOT TOUCH

- **`OratorEngine.swift`: DO NOT MODIFY.** `onChunkTiming`/`speak(chunks:)`/`isPaused`/`pause`/`resume`/`playbackPosition` are sufficient. If something seems missing, STOP and write a note instead.
- **`HotkeyManager.swift`: DO NOT MODIFY.** Never add chords; never re-add Option+Return.
- **`TextChunker.swift`, `ReadableText.swift`, `Pronunciations.swift`: DO NOT MODIFY.**
- No SwiftUI, no new dependencies, no Package.swift/Info.plist changes.
- Preserve existing behavior of the queue (`playNextInQueue` chaining on `.oratorSpeechFinished`), continuous reading, history recording, and per-app voices - you are changing HOW speech is invoked, not WHAT is spoken or WHEN.
- `previewVoice` / `synthesizeToFile` (audio export) are NOT speech playback - leave those paths alone.

## Verification

You cannot run xcodebuild (MLX Metal shaders). Type-check what you can; self-review for: exactly-one `engine.onChunkTiming` registrant, zero direct `engine.speak` calls outside the timeline, hydration correctness (open mid-utterance), document-replacement while window open, and no `stop()` on window open. The maintainer will build and run functional tests.

## Acceptance criteria

1. Highlight text anywhere → Option+' → speech starts → **open Reader → the text is there and the ball is already bouncing on the current word**, view auto-scrolled.
2. Opening the Reader never interrupts audio.
3. With the Reader open, pressing Option+' on a new selection replaces the document and follows live.
4. Queue/history/file/test-sentence speech all show up in the Reader identically.
5. Click-to-jump, sentence skip, Space, Option+P sync, Stop - all still work.
6. Cold open with nothing spoken: selection/clipboard fallback still works; Play starts tracked speech (visible in Reader AND stoppable by hotkey).
