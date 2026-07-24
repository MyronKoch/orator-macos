# PRD 27: Reader keeps the source document's formatting

## Problem
The Reader **flattens** everything. `ReaderSession.load` does `chunks = TextChunker.chunk(rawText)`
then `text = chunks.joined(separator: " ")`, and `TextChunker.normalize` collapses all whitespace. So
paragraphs, line breaks, and script layout are gone by the time the Reader displays. The user wants the
Reader to look like the source — a screenplay looks like a screenplay, paragraphs stay paragraphs.

## The honest difficulty (revised up from "moderate")
It's harder than a straight "show the original text," because the Reader **highlights as it reads**, and
the spoken text is now a *transformed* version of the source:
- `TextChunker` strips markdown, **expands numbers** ("25" → "twenty-five"), **expands currency/symbols**
  ("$15/mo" → "fifteen dollars per month"), applies user replacements, and collapses whitespace.
- So **spoken text ≠ displayed text**, and the current highlight ranges (computed on the flattened,
  transformed text) do NOT map onto the original layout. You can't just swap in the original string.

The core work is **threading source ranges through the transform pipeline** so each spoken chunk (and,
ideally, each word) knows the character range in the *original* text it came from — then highlighting
that source range in an original-layout display.

## Phased plan
### Phase 1 — preserve layout + chunk-level (sentence) highlight
- `ReaderSession` keeps the **original text** (with line breaks/paragraphs) as the display string.
- `TextChunker` returns, per spoken chunk, the **source NSRange** it originated from (add a
  `chunk(_:) -> [(spoken: String, sourceRange: NSRange)]` variant; the transforms must carry offsets).
  Where a transform makes an exact source range impossible (e.g. a number expanded to many words), map
  to the source token's range (the "25" that became "twenty-five").
- Display the original text with its paragraph style; highlight the **current chunk's source range**
  (sentence-level follow-along) instead of the flattened word range. Click-to-jump maps a clicked
  source range back to its chunk.
- This alone delivers "looks like the source + follows along by sentence," which is most of the value.

### Phase 2 — word-level highlight through the transforms (harder, optional)
- Align spoken words to source words within a chunk where a 1:1 mapping survives (plain words), and fall
  back to the chunk-level highlight across expanded tokens (numbers/symbols) where it doesn't.
- Only worth doing if Phase 1's sentence-level follow-along feels too coarse.

## Interactions / landmines
- Depends on the transform pipeline (`ReadableText`, `TextExpansions`, `UserReplacements`, `Pronunciations`)
  — each stage must be able to report source offsets, or the mapping degrades to sentence-level (which is
  the acceptable Phase 1 floor).
- Keep the existing auto-scroll, click-to-jump, and the follow-any-utterance behavior working.
- Don't touch the engine; this is display + range-mapping only.
- Combine well with **script mode (PRD 24)**: a parsed screenplay already has structure; the Reader
  showing it in script layout is the natural pairing.

## Acceptance
1. A multi-paragraph document displays with its paragraphs (not one flat blob).
2. Follow-along highlights the sentence/chunk being read, positioned in the original layout.
3. Click-to-jump still works against the displayed (original) text.
4. Auto-scroll, pause/resume, and live-follow unaffected. No engine changes.
