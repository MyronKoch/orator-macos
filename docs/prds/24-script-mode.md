# PRD 24: Script mode — cast a screenplay and read it as a table read

## The idea (real user pull: a screenwriter wants table reads)
A screenplay marks its speakers **explicitly**, so unlike prose Dramatize (PRD 15/22, which *guesses*),
script mode is deterministic. Load a script → Orator detects the characters → the user assigns a voice
to each (and a narrator voice for action) → Orator reads it as a **table read**, each character in their
voice, with the **Reader karaoke** following along. Casting persists **per script**.

## Massive reuse — most of this already exists
- **`SpeechSegment {text, voiceName}` + `OratorEngine.speak(segments:)`** — the per-voice playback path
  script mode targets. The parser's whole job is to emit `[SpeechSegment]`; everything downstream is done.
- **Reader window karaoke** — follows any segmented utterance already; a table read lights up for free.
- **`FileTextExtractor`** — already extracts **PDF** (PDFKit), rtf, txt, md, with a `noSelectablePDFText`
  error for scanned PDFs. Script loading builds on this.
- **`AppVoiceProfiles`** (`[String: Profile]` Codable in UserDefaults, get/set/remove/all) — the exact
  pattern to copy for the per-script cast store.
- **`DialogueCaster`'s `narratorVoice`** concept — reused for action/description lines.

**Net-new:** a screenplay parser (per format), a per-script cast store, and the script-mode UI (load +
cast table + play). The engine, Reader, voice list, and file loading are all reused.

## Architecture
1. **`ScriptParser`** → normalizes any supported format into `[ScriptElement]`:
   `characterCue(name)`, `dialogue(text)`, `action(text)`, `sceneHeading(text)`, `parenthetical(text)`,
   `transition(text)`. Format-specific front-ends feed one shared element model.
2. **`ScriptCaster`** → turns `[ScriptElement]` + the cast map + options into `[SpeechSegment]`:
   dialogue → the character's voice; action → narrator voice; scene headings/parentheticals/transitions →
   skipped or read per user option. (Mirrors `DialogueCaster` but driven by explicit cues, not heuristics.)
3. **`ScriptCast` store** (per-script): keyed by a **content hash** of the script (robust to file
   moves/renames; fall back to file path), value = `[characterName: voiceName]` + a narrator voice + a
   per-character speed override if wanted. Copy the `AppVoiceProfiles` Codable-in-UserDefaults shape.
   Auto-populate detected names on load; user can **add a name + assign a voice by hand** (the literal ask);
   unassigned characters get a clear "unassigned" state (prompt or a default rotation).

## Formats — PHASED by effort/reliability (user wants all four eventually)
- **Phase 1 — Fountain + "NAME:" (v1, do first).** One parser covers both: a character cue is an
  ALL-CAPS line on its own (Fountain) OR a `NAME:` line prefix (simple convention); dialogue is the
  following line(s); `INT./EXT.` = scene heading; `( … )` = parenthetical; `> …` / `TO:` = transition.
  Reliable and unambiguous. Handles the "well-marked script" case directly.
- **Phase 2 — Final Draft `.fdx`.** `XMLParser` over `<Paragraph Type="Character|Dialogue|Action|
  Parenthetical|Scene Heading|Transition">`. Structured and clean; a distinct but small parser.
- **Phase 3 — PDF (best-effort, EXPLICITLY fragile).** Build on `FileTextExtractor`'s extracted text;
  detect character cues by ALL-CAPS + centered/indented layout heuristics. Layout varies by export tool,
  so treat as best-effort and, when it misfires, **guide the user to export Fountain or .fdx**. Handle
  `noSelectablePDFText` (scanned/image PDFs) with a clear message. Do this LAST.

## UI (Codex-able)
- **Entry:** a "Script mode" / "Read as screenplay" action — open a script file (reuse the file picker +
  `FileTextExtractor`) or paste text; auto-detect format (Fountain/NAME: by cue shape, .fdx by extension,
  PDF by extension).
- **Cast table:** one row per detected character with a **voice popup**; a **Narrator** row; an **Add
  character** control (create a name + assign a voice manually). Live "unassigned" badges.
- **Play:** hit read → table read via `speak(segments:)`; Reader karaoke follows. Options: skip scene
  headings (default on), skip parentheticals (default on), skip transitions (default on).
- Cast **persists per script** and restores on reopen.

## The one real technical caveat: language-family mixing
`SpeechSegment`'s own note: voices should stay within one language family (all US **or** all GB) or a
**G2P reload** fires between segments → live stutter. A cast can mix families if the user assigns, say, a
US voice and a GB voice to different characters. Options: (a) **warn** when a cast spans families and
recommend one family for smooth live playback; (b) **pre-synthesize** the whole read (the offline
`synthesizeToFile` path exists) so mixed casts don't stutter live — a natural future enhancement, and it
also enables a one-click **"export the table read as audio"** (ties to backlog R1). v1: warn; note
pre-synthesis as the fix for mixed casts.

## Landmines — DO NOT
- Do NOT touch the OratorEngine concurrency core — script mode only *produces* `[SpeechSegment]`.
- 100% local — parsing + local voices only; nothing leaves the Mac.
- Key the cast store by **content hash** (stable across moves), not just a volatile file path.
- PDF is best-effort — never claim reliable PDF parsing; degrade gracefully + point to Fountain/.fdx.
- Warn on cross-language-family casts (G2P-reload stutter) rather than shipping a janny live read.

## Who builds what
- **Maintainer (or precisely-spec'd Codex):** `ScriptParser` (Phase 1 first), `ScriptCaster`, `ScriptCast`
  store. Build-verify with real sample scripts.
- **Codex:** the script-mode UI (entry + cast table + options), reusing the file picker and voice list.

## Verification
- Feed real sample scripts per supported format; assert correct segmentation (right speaker per line,
  action→narrator, headings/parentheticals handled per options).
- Table read plays each character in the assigned voice; Reader karaoke follows; cast persists per script
  and restores on reopen; cross-family cast triggers the warning.

## Acceptance criteria
1. Load a Fountain/"NAME:" script, auto-detect characters, assign voices (+ add one by hand), play a
   table read with correct per-character voices and narrator; Reader follows. (Phase 1)
2. `.fdx` parses correctly into the same flow. (Phase 2)
3. PDF is best-effort with graceful failure + guidance; scanned PDFs report clearly. (Phase 3)
4. Casting persists per script (content-hash keyed); cross-language-family casts warn.
5. No engine changes; 100% local; builds/signs clean.
