# PRD 28: Drag-and-drop files + file-based Finder Services

## Goal
1. **Drag a file onto Orator** (PDF, txt, md, rtf — a script "or whatever") and have it parsed and put
   on the Reader board, ready to read.
2. **Bonus — file-based Finder Services:** right-click a file → **"Read with Orator"** / **"Queue in
   Orator."** Like the existing *text* Services, but operating on the file.

## What already exists (so this is smaller than it looks)
- **`FileTextExtractor`** already extracts **PDF (PDFKit), txt, md, rtf** → text, with a
  `noSelectablePDFText` error for scanned/image PDFs. **Parsing is done** for these formats.
- The app already has a **"Read File…"** menu path and **text-based** macOS Services
  (`OratorServiceProvider.speakWithOrator` / `addToOratorQueue`, Info.plist `NSServices`).
- So the new work is the **drop targets** and **extending Services to accept files** — not a parser.

## Part A — Drag-and-drop targets
- **Reader window:** register the Reader's content view (or `textView`) for the `.fileURL` dragged type.
  In `draggingEntered`, accept only supported UTIs (show the copy cursor); in `performDragOperation`,
  resolve the file URL(s) → `FileTextExtractor.extractText(from:)` on a background queue → load into the
  `ReaderSession` and start reading. Multiple files → enqueue them in order.
- **Menu-bar status item:** the `NSStatusItem.button` can `registerForDraggedTypes([.fileURL])` so
  dropping a file on the Orator icon reads it. Same extract → read/queue path.
- Show progress/feedback for large PDFs (extraction can take a beat); never block the main thread.

## Part B — File-based Services (bonus)
- Add `NSServices` entries to Info.plist with **`NSSendTypes` including file URLs**
  (`public.file-url` / legacy `NSFilenamesPboardType`) for **"Read with Orator"** and **"Queue in
  Orator."** Optionally scope by UTI (`public.pdf`, `public.plain-text`, `public.rtf`, and later script
  types) so the items only appear for readable files.
- `OratorServiceProvider` gains file handlers: pull file URL(s) off the service pasteboard →
  `FileTextExtractor` → speak / enqueue. Reuse the existing speak/queue plumbing.
- **Known caveat (from the text Services work):** app Services menus are cached — the new items appear
  after a **log out/in** (or `pbs`-registry refresh). Document this in the UI/README so it isn't a
  "bug."

## Format scope (v1)
- v1 reads via `FileTextExtractor` (txt/md/rtf/pdf) — a dropped screenplay PDF extracts to text and reads
  as plain prose.
- **Script-aware** parsing (Fountain/.fdx → per-character cast) is **PRD 24 (script mode)**, a separate
  build. Drag-drop + script mode compose: drop a `.fountain` → (with PRD 24) parse to a cast; without it,
  read as text. Note this so expectations are clear.

## Landmines
- Register `NSPasteboard.PasteboardType.fileURL`; validate UTIs in `draggingEntered` so only supported
  files show the drop cursor (reject folders/unknown types cleanly).
- Extraction on a background queue; `noSelectablePDFText` (scanned PDF) → clear message, no crash.
- Orator is **not sandboxed** (Developer ID, needs Accessibility), so dropped/serviced file access is
  unrestricted — no security-scoped bookmark dance needed. (If sandboxing is ever adopted, revisit.)
- Services caching → re-login; don't treat the delay as a defect.
- Don't touch the engine; this is intake plumbing feeding the existing read/queue paths.

## Who builds
- **Drag-drop targets** (Reader + status item): AppKit drag handling — Codex-able with a tight spec.
- **File Services** (Info.plist `NSServices` + provider file handlers): maintainer (mirrors the existing
  text-Services wiring; the Info.plist + provider are the fiddly part).

## Acceptance
1. Dropping a PDF/txt/md/rtf on the **Reader window** loads and reads it.
2. Dropping a file on the **menu-bar icon** reads it; multiple files queue.
3. Right-click a file in Finder → **"Read with Orator"** / **"Queue in Orator"** (after a re-login).
4. Scanned/unsupported files show a clear message; no crash; main thread never blocks.
