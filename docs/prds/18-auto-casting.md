# PRD 18: Auto-Casting — stories read themselves in character

## The idea

When enabled, Orator detects dialogue in a passage and reads it like a radio drama: the narrator keeps the user's voice, and each detected speaker gets a distinct, consistent voice from the 26 stock voices. Fully local, automatic, heuristic — **no LLM, no voice cloning** (this stays firmly out of the voice-production lane). Paste a short story, hear it cast itself. This is the "send it to a friend" feature.

Scope: a **heuristic v1**. It will not be perfect on hard prose; it must be *pleasant and safe* — a misattributed line is fine, a crash or a wrong-language reload is not.

## What the engine already provides (DO NOT MODIFY THE ENGINE)

The maintainer has landed the per-segment-voice API. Read `Sources/Orator/SpeechSegment.swift` and `Sources/Orator/OratorEngine.swift`:

- `struct SpeechSegment { let text: String; let voiceName: String }`
- `engine.speak(segments: [SpeechSegment]) throws -> Int` — renders a cast list. Each segment's text is chunked internally (via `TextChunker.chunk`) with the segment's voice held constant; unresolved voices fall back to the current voice. Returns the utterance ID, or -1 if empty. It emits the same `ChunkTiming` callbacks as `speak(chunks:)`, indexed 0..N over the **flattened** chunk list (concatenation of `TextChunker.chunk(segment.text)` across segments, in order).
- `engine.voiceNames: [String]` — the available voices (e.g. `af_heart`, `am_adam`, `bf_emma`, `bm_george`).

Because the engine flattens segments through `TextChunker.chunk` deterministically, you can reproduce the exact chunk list by doing the same flattening yourself — this is how the timeline stays aligned (below).

## The voice pool (for assignment)

Voice names encode region+gender: `{a|b}{f|m}_name` — `a`=American, `b`=British, `f`=female, `m`=male. In the bundle:

- US female (`af_`): alloy, aoede, bella, heart, jessica, kore, nicole, nova, river, sarah, sky
- US male (`am_`): adam, echo, liam, michael, onyx, puck, santa
- UK female (`bf_`): alice, emma, isabella, lily
- UK male (`bm_`): daniel, fable, george, lewis

Keep every cast voice in the **narrator's region** (all `a*` or all `b*`) so no segment triggers a G2P/language reload mid-passage.

## Files

- **NEW** `Sources/Orator/DialogueCaster.swift` — pure, UI-free, unit-testable. The heart of the feature.
- **EDIT** `Sources/Orator/SpeechTimeline.swift` — a cast-aware speak path + per-chunk voice memory so Reader jumps stay in-voice.
- **EDIT** `Sources/Orator/ReaderSession.swift` — route `play(fromChunk:)` through the timeline's stored state (small change; see below).
- **EDIT** `Sources/Orator/AppDelegate.swift` — a persisted "Auto-cast dialogue" menu toggle; route the speak-selection paths through the caster when enabled.

## DialogueCaster (the heuristic — this is the IP)

```swift
enum DialogueCaster {
    /// Split text into ordered narration/dialogue segments and assign voices.
    /// narratorVoice keeps the narrator's lines; speakers draw distinct voices
    /// from `pool` (same region as narratorVoice). Deterministic: the same
    /// speaker label always maps to the same voice within one call.
    static func cast(text: String, narratorVoice: String, pool: [String]) -> [SpeechSegment]
}
```

Algorithm:

1. **Find quoted spans.** Match balanced double-quote pairs — straight `"..."` and curly `"..."`. Treat only these as speech delimiters; **never** treat apostrophe `'` / `'` as a delimiter (contractions, possessives). Unbalanced trailing quote → treat the remainder as narration (bail safely, never crash).
2. **Build ordered segments.** Walk the string start→end producing alternating narration and dialogue substrings, in original document order, using the **original substring** for each (keep quote marks; Kokoro handles them). Drop empty/whitespace-only spans.
3. **Attribute each dialogue span** to a speaker label:
   - Inspect the narration immediately **after** the closing quote (to the next sentence end, ~cap 48 chars) and immediately **before** the opening quote for an attribution: a speech verb (`said, asked, replied, answered, whispered, shouted, murmured, cried, added, continued, began, muttered, exclaimed`) adjacent to either a **capitalized name** or a **pronoun** (`he/she/they/I`).
   - Name → that name is the speaker label. Pronoun `he`/`she` → resolve to the most recent named speaker whose inferred gender matches; if none, a generic label `__he`/`__she`. `I`/`they` → most recent distinct speaker, else generic.
   - **No attribution found → alternation:** assign the *other* of the last two distinct dialogue speakers (the dominant two-person-dialogue pattern). If only one prior speaker, reuse it; if none, `__spk1`.
4. **Assign voices** (deterministic):
   - Narrator segments → `narratorVoice`.
   - `pool` = `engine.voiceNames` filtered to the narrator's region, minus `narratorVoice`, in a stable order that **alternates gender** (m,f,m,f…) for maximum contrast.
   - Each distinct speaker label → the next unused pool voice on first appearance, **preferring the inferred gender** when known (male name/he → `?m_`, female name/she → `?f_`); fall back to any unused voice, then wrap by stable hash if speakers exceed the pool.
5. **Return** the ordered `[SpeechSegment]`. Text with **no detected dialogue** returns a single narrator segment — identical to plain speech.

Keep gender inference tiny and safe: a short built-in male/female first-name set for the common cases, plus pronoun signals; unknown names get a voice by round-robin. Getting gender wrong costs one oddly-cast character, never a failure.

## SpeechTimeline changes (keep the Reader working)

Add a cast path alongside the existing one. Extend `Utterance` with one optional field:

```swift
var chunkVoices: [String]?   // per-chunk voice, aligned to `chunks`; nil = single-voice (current behavior)
```

- **NEW** `func speak(segments: [SpeechSegment]) throws` — flatten segments into `(chunk, voice)` pairs by running `TextChunker.chunk(segment.text)` per segment (SAME order the engine uses), store `chunks` + `chunkVoices`, call `engine.speak(segments:)` with the original segments, record the `Utterance` (baseIndex 0), emit `.utteranceStarted`. Timing indices line up because both flatten identically.
- The existing `speak(chunks:from:)` stays for single-voice; set `chunkVoices = nil` there.
- **Voice-aware jump:** where the timeline restarts from a chunk index, if `chunkVoices != nil`, rebuild a segment list from `chunks[i...]` zipped with `chunkVoices[i...]` (merge consecutive equal-voice chunks into one `SpeechSegment`) and call `engine.speak(segments:)`; else use the current single-voice `speak(chunks:from:)`. Keep the utterance's `chunks`/`chunkVoices` identity across a jump (a jump re-slices, it doesn't re-cast).

## ReaderSession change (small)

`play(fromChunk:)` currently calls `timeline.speak(chunks: chunks, from: index)`. Change it to call a single timeline entry (e.g. `timeline.replay(fromChunk: index)`) that uses the timeline's stored `chunks`/`chunkVoices` and does the voice-aware-or-plain restart described above. Everything else in ReaderSession (alignment, highlighting, timer) is unchanged — casting is invisible to the highlighter; it only changes which voice speaks.

## AppDelegate integration

- Persisted **"Auto-cast dialogue"** toggle (menu item with a checkmark; `Pref.autoCast`, default **off**). Place it near the Voice/Speed controls.
- When ON, the **speak-selection** paths cast before speaking: build `segments = DialogueCaster.cast(text: text, narratorVoice: engine.currentVoice, pool: engine.voiceNames)` and call `timeline.speak(segments:)`; when OFF, keep `timeline.speak(text:)`. Apply this to `speakText` and clipboard/selection speech. **Queue playback and audio export stay single-voice for v1** (note it; casting the queue is a later item).
- Do not change the queue-chaining, history, per-app-voice, or pause/resume behavior.

## Landmines — DO NOT TOUCH

- `OratorEngine.swift`: DO NOT MODIFY. `speak(segments:)` is sufficient; if something seems missing, STOP and note it.
- `HotkeyManager.swift`: DO NOT MODIFY. No new hotkeys in this PRD (an auto-cast hotkey is a later item). Never re-add Option+Return.
- `TextChunker.swift`, `ReadableText.swift`, `Pronunciations.swift`: DO NOT MODIFY. Use `TextChunker.chunk` exactly as-is so timeline/engine chunking stays identical.
- Preserve the Reader's word-highlighting, auto-scroll, and live-follow exactly — casting must be invisible to all of it except the voice heard.
- No SwiftUI, no dependencies, no Package.swift/Info.plist/scripts changes.
- No voice cloning, no per-word voices — segment granularity only.

## Verification

No xcodebuild in your sandbox; type-check what you can. Self-review: the no-dialogue path returns exactly one narrator segment (plain-speech parity); apostrophes never split; unbalanced quotes never crash; timeline `chunks`/`chunkVoices` stay the same length; voice-aware jump merges runs correctly; all cast voices share the narrator's region. The maintainer builds, then functionally tests casting audio (multiple voices) and Reader highlighting over a cast passage.

## Acceptance criteria

1. Toggle off → behavior identical to today (single voice), Reader unaffected.
2. Toggle on, a two-person dialogue passage → narrator in the user's voice, the two speakers in two distinct, consistent voices; highlighting still follows every word.
3. Plain prose with no quotes, toggle on → sounds exactly like single-voice speech.
4. Emoji/URLs/numbers/contractions never crash the caster; apostrophes never start a "quote."
5. In the Reader, clicking a sentence in a cast passage restarts in the correct voice for that sentence.
6. All cast voices are the narrator's region (no mid-passage language reload).
