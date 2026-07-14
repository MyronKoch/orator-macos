# PRD 03 — Clean / Structure-Aware Reading

**Status:** ready for implementation
**Scope:** text preprocessing only. New file + one edit to `TextChunker.swift`.
**Risk to core:** none. Pure string transformation, same integration point as pronunciation.

## Problem

When the selected text contains formatting (Markdown, raw URLs, code, list markers), Kokoro reads the literal symbols. Selecting `**Important:** see [the docs](https://example.com/x)` currently speaks something like "asterisk asterisk Important colon asterisk asterisk see the docs h-t-t-p colon slash slash...". It should say "Important: see the docs."

## Solution

Add a preprocessing pass that converts common structural/formatting markup into clean, naturally-spoken text, and inserts pauses at structural boundaries. Applied to the full text before chunking, so nothing is split awkwardly.

## Requirements

### 1. New file `Sources/Orator/ReadableText.swift`

Create an `enum ReadableText` with:

```swift
static func clean(_ text: String) -> String
```

It transforms the input as follows. Order the rules carefully so earlier rules don't corrupt later ones.

**Links & URLs**
- Markdown links `[label](url)` → `label`
- Markdown images `![alt](url)` → `alt` (or drop if alt is empty)
- Bare URLs (`https://…`, `http://…`, `www.…`) → replace with the word "link" (do not spell out the URL). A long naked URL read aloud is useless.

**Emphasis / inline markup**
- Bold/italic markers `**x**`, `*x*`, `__x__`, `_x_` → `x`
- Strikethrough `~~x~~` → `x`
- Inline code `` `x` `` → `x`

**Block structure (convert to spoken cadence via punctuation)**
- Headings: a line starting with one or more `#` → strip the `#`/spaces; ensure the line ends with a period so the voice pauses after it.
- List items: leading `-`, `*`, `+`, or `1.`/`2.` markers → remove the marker; ensure each item ends with a period/pause so items don't run together.
- Blockquote leading `>` → remove the marker, keep the text.
- Horizontal rules (`---`, `***`, `___` on their own line) → remove entirely.
- Table rows (lines with `|` separators) → replace `|` with commas so cells are read as a list; drop separator rows like `|---|---|`.

**Code blocks (fenced ``` … ```)**
- Replace the entire fenced block with the short spoken placeholder `"(code block)"`. Do not read code line by line.

**Cleanup**
- Collapse 3+ newlines to a paragraph break; leave single/double newlines for the existing normalizer to handle.
- Never emit the raw characters `* _ ~ # \` > |` as leftover noise from the rules above.

Keep it dependency-free (Foundation only; regex via `NSRegularExpression` or `String` APIs). Whole thing is pure and synchronous.

### 2. Integration in `TextChunker.swift`

In `chunk(_:)`, apply cleaning **first**, before normalization and pronunciation. Final order inside `chunk`:

```
ReadableText.clean(raw)  →  normalize(...)  →  Pronunciations.shared.apply(...)  →  sentence split
```

Make the minimal edit to insert the `ReadableText.clean` call at the top of `chunk`. Do not change anything else in TextChunker, and do not alter `normalize` or the splitting logic.

### 3. Robustness

- Plain text with no markup must pass through essentially unchanged (aside from whitespace normalization already done downstream).
- Must never throw or crash on unusual input (emoji, RTL text, code-like punctuation in prose). Prefer leaving text alone over aggressive deletion when a rule is ambiguous.

## Landmines — DO NOT TOUCH

1. **Do not modify `OratorEngine.swift`** — none of the playback/concurrency state, and not the new `synthesizeToFile` method either.
2. **Do not touch** `HotkeyManager.swift`, `AppDelegate.swift`, `Pronunciations.swift`, or the build scripts.
3. Only new file `ReadableText.swift` + the single insertion in `TextChunker.chunk`.
4. **No third-party dependencies.** Foundation only.
5. Swift 6.2 strict concurrency is ON. `ReadableText` is a stateless enum of static functions — keep it that way (no shared mutable state).

## Build & verify

- Build via `./scripts/build-app.sh` (xcodebuild; NOT `swift build`).
- Confirm it compiles. Do not sign, notarize, commit, or release — leave changes in the working tree.
- Report the files changed and paste the full `ReadableText.swift` plus the one-line `TextChunker` diff. Include 3–4 before/after examples of representative inputs (a heading, a markdown link, a bulleted list, a fenced code block).

## Out of scope

- Speaking math notation (separate future PRD)
- HTML tag parsing (selections are usually plain/markdown text, not raw HTML)
- Language-specific rules
