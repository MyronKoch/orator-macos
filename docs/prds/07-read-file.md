# PRD 07 — Read a File

**Status:** ready for implementation
**Scope:** `AppDelegate.swift` + one small new file. Zero engine changes.
**Risk to core:** none. Extracts text from a file and calls existing public methods (`engine.speak`, `engine.synthesizeToFile`).

## Problem

To hear a document today you must open it in its app, select all, and press the hotkey. Users want to point Orator at a file directly: "read me this PDF / this Markdown note / this text file."

## Solution

Two menu items:
- **"Read File…"** — open a file, extract its text, and speak it.
- **"Export File to Audio…"** — open a file, extract its text, and export it to an `.m4a` (reuse the existing export flow).

Supported types: `.txt`, `.md`, `.markdown`, `.text`, `.rtf`, `.pdf`.

## Requirements

### 1. New file `Sources/Orator/FileTextExtractor.swift`

A stateless enum with:

```swift
enum FileTextExtractor {
    /// UTTypes to allow in the open panel.
    static let supportedTypes: [UTType]   // .plainText, .init(filenameExtension: "md")..., .rtf, .pdf

    /// Extract readable plain text from a file, or throw.
    static func extractText(from url: URL) throws -> String
}
```

Extraction rules:
- **Plain text / Markdown** (`.txt`, `.md`, `.markdown`, `.text`): read as a `String` (try UTF-8, fall back to `String(contentsOf:usedEncoding:)` / `.utf8`/`.isoLatin1`). Markdown is passed through as-is — the existing `ReadableText.clean` pass in `TextChunker` already strips its formatting, so do NOT re-clean here.
- **RTF** (`.rtf`): load via `NSAttributedString(url:options:documentAttributes:)` with `.documentType: .rtf`, then take `.string`.
- **PDF** (`.pdf`): use `PDFKit` — `PDFDocument(url:)`, concatenate each page's `.string` with newlines. If the PDF has no extractable text (scanned image), throw a clear error ("This PDF has no selectable text").
- Trim the result; if empty, throw an error ("No readable text in this file").

Foundation + AppKit + PDFKit + UniformTypeIdentifiers only. Keep it pure/stateless.

### 2. Menu items (`AppDelegate.rebuildMenu`)

In the engine-available section (near "Speak Clipboard" / the export items), add:
- **"Read File…"** → `#selector(readFile)`
- **"Export File to Audio…"** → `#selector(exportFileToAudio)`

### 3. Handlers (`AppDelegate`)

- `readFile()`: show an `NSOpenPanel` (allowedContentTypes = `FileTextExtractor.supportedTypes`, single file). On OK, extract text off the main thread (`DispatchQueue.global`), then on the main queue: if empty/failed, show the existing-style notification; otherwise call the SAME speak path used elsewhere — i.e. run `engine.speak(text)` on a background queue exactly as `toggleSpeech` does after capture. (Do not simulate Cmd+C; the text comes from the file.)
- `exportFileToAudio()`: same open panel + extraction, then reuse the existing export routine. Factor the current export-save-panel logic (from PRD 02's `exportToAudio(_:)`) so both clipboard/selection and file paths share it — call that shared method with the extracted text. Do not duplicate the save-panel code.

### 4. Reuse, don't duplicate

- Reuse the existing `exportToAudio(_ text:)` method (save panel + `engine.synthesizeToFile` + progress tooltip + reveal-in-Finder) for "Export File to Audio…". If it's currently private and file-agnostic, just call it.
- Reuse the existing notification helper for errors.

## Landmines — DO NOT TOUCH

1. **Do not modify `OratorEngine.swift`** — use `speak` / `synthesizeToFile` as they are.
2. Do not touch `HotkeyManager.swift`, `TextChunker.swift`, `Pronunciations.swift`, `ReadableText.swift`, `AppVoiceProfiles.swift`, or the build scripts.
3. Only `AppDelegate.swift` + new `FileTextExtractor.swift`.
4. No third-party dependencies (PDFKit, UniformTypeIdentifiers, AppKit, Foundation are all system frameworks — fine).
5. Swift 6.2 strict concurrency ON; `AppDelegate` is `@MainActor`. Do extraction off the main thread, then hop back to main for UI + calling the engine (mirror how `toggleSpeech` dispatches `engine.speak` on a background queue).
6. Do not apply `ReadableText.clean` here — `TextChunker` already does it downstream. Double-cleaning could corrupt text.

## Build & verify

- Build via `./scripts/build-app.sh` (xcodebuild; NOT `swift build`). If sandbox blocks the build, ensure it type-checks and say so.
- Do not sign, notarize, commit, or release — leave changes in the working tree.
- Report files changed; paste `FileTextExtractor.swift`, the new menu items, and the two handlers.

## Out of scope

- `.docx` / Office formats
- OCR for scanned PDFs
- Batch / folder reading
- Remembering recently-read files
