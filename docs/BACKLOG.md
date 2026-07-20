# Orator — Radar / Backlog

Lightweight capture of ideas and reported friction that are NOT yet scheduled work.
Promote an item to a numbered PRD in `docs/prds/` when it's ready to build.

## Requested by users

### R1 — Shareable audio export (send-to-phone)
**Status:** partially already shipped. **Priority:** high (discoverability, not code).
- The menu already has **Export ▸ (Selection / Clipboard / File) to Audio…** producing `.m4a`
  (AAC in an MP4 container). That file AirDrops to iPhone and plays natively — this already
  satisfies "highlight something and send it to my phone to listen to."
- **The real gap is that nobody knows it exists.** Surface it: README demo GIF, and consider
  a "Share to iPhone" affordance / a share-sheet hook so the flow is one action.
- **`.mp3` specifically:** Apple's frameworks have no built-in MP3 *encoder*; literal MP3 would
  need a third-party lib (e.g. LAME) and its licensing. Recommendation: **stay `.m4a`** — it
  plays on every iPhone and modern Android. Only add MP3 if a concrete requester needs it.

### R2 — Weird pronunciations / formatting artifacts
**Status:** needs reproduction cases before it's actionable. **Priority:** medium.
- Report: "weird pronunciations and weird things during certain formatting."
- Relevant existing code: `TextChunker.normalize(_:)`, `ReadableText.swift` (structure-aware
  cleaning), `Pronunciations.swift` (user dictionary). The pronunciation dictionary already
  lets a user fix a specific mispronounced word (Word → Say-it-like).
- **Action needed:** collect concrete examples (the exact source text + what it said wrong).
  Likely culprits to check once we have samples: markdown/list markers, code blocks, URLs,
  numbers/dates, abbreviations, emoji. Fixes probably live in `normalize`/`ReadableText`, not
  the engine. Cheap-if-narrow; unbounded if we chase every edge case — so drive it from real
  reported strings, not speculation.

### R3 — Smarter voice-fit for Dramatized reading ("cast the right voice for the quote")
**Status:** phased; partially exists. **Priority:** medium (a "wow" differentiator).
- Today `DialogueCaster` already does **gender-aware** assignment (picks a gendered voice from
  cues in the narration). The ask: pick the voice that best *fits* the character/quote, not just
  a round-robin by gender.
- **This is NOT out of reach — there's a 100%-local path, in two phases:**
  - **Phase A (cheap, heuristic, extends the existing caster):** widen the cue detection beyond
    gender — age ("old man", "the child"), delivery ("boomed", "whispered", "hissed"), and role —
    then map to the closest voice in the palette. Brittle but free and fully on-device. Incremental.
  - **Phase B (the real "wow", local LLM as a casting director):** feed the passage to a *local*
    model (the user already runs LM Studio) to profile each speaker and assign the best-fit voice.
    Fully private/on-device if it uses a bundled or local model — honors the no-cloud rule.
- **Two hard gates before Phase B is worth it:**
  1. **Voice palette size.** With ~26 English Kokoro voices, "best fit" is coarse. Casting quality
     is capped by voice variety → **PRD 21 (more voices/languages) is the prerequisite.**
  2. **Shippability.** Relying on the user's own LM Studio isn't shippable to other users; a bundled
     small model adds weight. Decide the model-delivery story before committing.
- **Verdict:** not a stretch too far — a phased, on-device path exists. Do Phase A opportunistically;
  Phase B after the voice palette grows (PRD 21). Not part of the v1.3.0 dramatize work.
