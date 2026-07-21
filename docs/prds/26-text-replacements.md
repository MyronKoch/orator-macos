# PRD 26: Built-in expansions + user-configurable text replacements

## Problem (from testing)
1. The symbol sanitizer (PRD in `ReadableText.sanitizeSymbols`) now drops unknown glyphs (e.g. `→`)
   to a **silent pause** — correct default (no universal reading for an arrow), but there's no way for
   a user to *choose* a spoken form.
2. Patterns like **`$15/mo`** should verbalize as **"fifteen dollars per month"** but currently read as
   "15" (currency dropped) + a pause. This needs pattern-aware expansion.
3. The existing **`Pronunciations`** store can't help: it's **whole-word only** (word-boundary regex) so
   it can't match symbols/patterns, and it runs **after** the sanitizer, so symbols are already gone.

## Solution — two layers, both BEFORE the sanitizer
### Layer 1 — Built-in expansions (maintained by us; unambiguous cases)
A small, ordered regex pass covering the common cases so users don't have to configure the obvious:
- **Currency + amount:** `\$(\d[\d,]*(?:\.\d+)?)` → `$1 dollars`; same for `€`→euros, `£`→pounds.
  (Kokoro reads the number as words, so "$15" → "15 dollars" → *"fifteen dollars"*.)
- **Rate abbreviations:** `/mo` → " per month", `/yr` → " per year", `/wk` → " per week",
  `/hr` → " per hour", `/day` → " per day". (Word-boundaried so URLs/paths aren't mangled — apply
  only when preceded by a digit or letter and followed by a boundary.)
- Keep this list SMALL and unambiguous. Anything debatable belongs in Layer 2, not here.

### Layer 2 — User text replacements (the PushToTranscribe-style feature)
An **ordered** list of rules the user edits in Settings. Each rule: `find`, `replace`, `isRegex`
(bool), `enabled` (bool). Applied in order. This is where the user handles the long tail — arrows to
their preferred word, domain jargon, custom units, etc. Regex mode lets power users write patterns
(with capture-group refs in `replace`).

## Pipeline ordering (the crux — get this exactly right)
Rewrite `TextChunker.chunk` so the stages run in this order:
```
raw
 → ReadableText.markdownClean   (strip markdown STRUCTURE only; split sanitize out — see below)
 → UserReplacements.apply       (Layer 2, ordered, literal + regex)
 → BuiltinExpansions.apply      (Layer 1, currency + rates)
 → ReadableText.sanitizeSymbols (safety net: map &=+%@×÷°, drop the rest to a pause)
 → normalize                    (collapse whitespace)
 → Pronunciations.apply         (word-level "say it like", unchanged)
 → chunk
```
- **Split `ReadableText.clean`** into `markdownClean` (the existing markdown steps) and the separate
  `sanitizeSymbols`, so the two user/expansion layers can slot between them. Today `clean` does both;
  that's why symbols die before replacements can run.
- Both new layers run **after** markdown structure is gone (so `*`/`#`/`|` don't confuse rules) and
  **before** sanitize (so rules can catch symbols the sanitizer would otherwise drop).
- In the Dramatize path this all runs **per-segment** (after `DialogueCaster.cast`), so quotes needed
  for casting are untouched — same as the sanitizer today.

## Store + engine (`UserReplacements`, mirror `Pronunciations`)
- `[Rule]` where `Rule = {find, replace, isRegex, enabled}`, persisted in UserDefaults (Codable array).
- `apply(to:)` runs enabled rules in order. For regex rules: compile with a guard; **a malformed or
  catastrophic pattern must be skipped, never crash or hang** — validate on add, and wrap application
  defensively (bounded matching). Literal rules use plain string replacement (case-insensitive option).
- Seed EMPTY (built-in expansions cover the common cases); the user adds their own.

## UI (Codex — mirror the Pronunciations editor)
- A **"Text Replacements"** section (its own settings area, or under Voices/General): a table with
  **Find | Replace | Regex | ✓** columns, Add/Remove, drag-to-reorder (order matters), and a live
  "test" field would be a nice-to-have (type sample text, see the rewritten result).
- A one-line explainer distinguishing it from Pronunciations: *"Rewrite symbols, abbreviations, or
  phrases before reading (supports regex). For how to pronounce a word, use Pronunciations."*

## Relationship to Pronunciations (keep separate)
- **Pronunciations** = how to SAY a word (word-bounded; "MLX" → "em ell ex"). Unchanged.
- **Text Replacements** = rewrite symbols/phrases/patterns before speech (regex-capable, ordered).
- Different matching semantics → keep them separate features; document the division in the UI.

## The arrow question (answered)
There's no universally-correct reading for `→`, so the DEFAULT stays a **silent pause**. A user who
wants it spoken adds a replacement (`→` → "to" / "leads to" / "arrow"). This is precisely why the
feature exists — the ambiguous cases are user choice, not a hardcoded guess.

## Landmines
- Ordering above is load-bearing — replacements/expansions MUST precede `sanitizeSymbols`.
- User regex must fail safe (skip broken/catastrophic patterns; never crash or hang the reader).
- Don't strip the quotes Dramatize depends on; this runs per-segment after casting anyway.
- Built-in expansions stay small + unambiguous; everything debatable is user-configurable.
- No engine-core changes; this is all pre-synthesis text rewriting.

## Who builds
- **Maintainer:** the pipeline re-ordering (split `clean`), `BuiltinExpansions`, and the
  `UserReplacements` store + safe regex application. Build-verify.
- **Codex:** the Text Replacements settings UI (table, add/remove/reorder, regex toggle, test field).

## Acceptance
1. `$15/mo` reads "fifteen dollars per month" with no user config (built-in expansions).
2. A user rule `→` → "leads to" makes arrows speak that; with no rule, arrows stay a pause.
3. Regex rules work (e.g. `(\d+)°C` → "$1 degrees Celsius"); a malformed rule is skipped, not fatal.
4. Pronunciations still works and is clearly distinct in the UI.
5. Nothing reads as a stray "x"; Dramatize/quotes unaffected; builds clean.
