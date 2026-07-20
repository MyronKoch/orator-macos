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
