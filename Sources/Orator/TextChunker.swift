import Foundation

/// Splits arbitrary selected text into TTS-sized chunks.
///
/// KokoroTTS rejects inputs over 510 phoneme tokens. Phoneme count roughly
/// tracks character count, so we pack sentences into chunks capped well below
/// that ceiling. Sentence boundaries keep prosody natural; a hard word-split
/// fallback handles pathological run-on text.
enum TextChunker {

    static let maxChunkLength = 350

    /// Clean, expand, and normalize text, then split into speakable chunks.
    ///
    /// Order is load-bearing: markdown structure is stripped first, THEN text
    /// expansions (numbers/currency/rates) run while content symbols are still
    /// present, THEN the symbol sanitizer drops anything left, THEN whitespace
    /// is collapsed and word pronunciations applied.
    static func chunk(_ raw: String) -> [String] {
        var text = ReadableText.markdownClean(raw)
        text = UserReplacements.shared.apply(to: text)
        text = TextExpansions.apply(to: text)
        text = ReadableText.sanitizeSymbols(text)
        text = normalize(text)
        text = Pronunciations.shared.apply(to: text)
        guard !text.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""

        for sentence in splitSentences(text) {
            if sentence.count > maxChunkLength {
                // Flush what we have, then hard-split the oversized sentence.
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: hardSplit(sentence))
                continue
            }
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= maxChunkLength {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// A speakable chunk plus the range it occupies in the FORMATTED display
    /// string (source line breaks preserved). Lets the Reader show the source
    /// layout while playing correct (transformed) speech.
    struct DisplayChunk {
        let displayRange: NSRange
        let spoken: String
    }

    /// Produce a formatted display string (markdown structure stripped but line
    /// breaks/paragraphs kept) plus per-chunk spoken text and each chunk's range
    /// in that display string. Splitting happens on the DISPLAY first (so ranges
    /// are exact), then each unit is transformed for speech per-sentence.
    static func readerChunks(_ raw: String) -> (display: String, chunks: [DisplayChunk]) {
        let display = ReadableText.markdownClean(raw)
        guard !display.isEmpty else { return (display, []) }

        var chunks: [DisplayChunk] = []
        var pendingStart: Int?
        var pendingEnd = 0
        var pendingSpoken = ""

        func flush() {
            defer { pendingStart = nil; pendingSpoken = "" }
            guard let start = pendingStart, !pendingSpoken.isEmpty else { return }
            chunks.append(DisplayChunk(
                displayRange: NSRange(location: start, length: pendingEnd - start),
                spoken: pendingSpoken
            ))
        }

        for unit in sentenceUnits(in: display) {
            let spoken = speechTransform(unit.text)
            let unitEnd = unit.range.location + unit.range.length
            if spoken.isEmpty {
                // Display-only text (e.g. a line of symbols): keep it visible by
                // extending the current chunk's highlight range to cover it.
                if pendingStart != nil { pendingEnd = unitEnd }
                continue
            }
            if spoken.count > maxChunkLength {
                flush()
                chunks.append(contentsOf: splitLongUnit(unit.range, unit.text, in: display))
                continue
            }
            if pendingStart == nil {
                pendingStart = unit.range.location
                pendingSpoken = spoken
                pendingEnd = unitEnd
            } else if pendingSpoken.count + 1 + spoken.count <= maxChunkLength {
                pendingSpoken += " " + spoken
                pendingEnd = unitEnd
            } else {
                flush()
                pendingStart = unit.range.location
                pendingSpoken = spoken
                pendingEnd = unitEnd
            }
        }
        flush()
        return (display, chunks)
    }

    /// The per-sentence speech transform (everything after markdownClean, which
    /// readerChunks already applied to the whole document).
    private static func speechTransform(_ text: String) -> String {
        var result = UserReplacements.shared.apply(to: text)
        result = TextExpansions.apply(to: result)
        result = ReadableText.sanitizeSymbols(result)
        result = normalize(result)
        result = Pronunciations.shared.apply(to: result)
        return result
    }

    /// Split text into sentence units, each with its NSRange in `text`.
    private static func sentenceUnits(in text: String) -> [(range: NSRange, text: String)] {
        var units: [(NSRange, String)] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if character == "." || character == "!" || character == "?" || character == ";" {
                appendUnit(text, start..<next, to: &units)
                start = next
            }
            index = next
        }
        if start < text.endIndex { appendUnit(text, start..<text.endIndex, to: &units) }
        return units
    }

    private static func appendUnit(
        _ text: String,
        _ range: Range<String.Index>,
        to units: inout [(NSRange, String)]
    ) {
        let substring = String(text[range])
        guard substring.contains(where: { !$0.isWhitespace }) else { return }
        units.append((NSRange(range, in: text), substring))
    }

    /// Word-split an over-long unit into <= maxChunkLength display slices, each
    /// carrying its own display sub-range (offset into the whole display string).
    private static func splitLongUnit(_ range: NSRange, _ text: String, in display: String) -> [DisplayChunk] {
        var result: [DisplayChunk] = []
        var sliceStart = text.startIndex
        var lastSpace: String.Index?
        var index = text.startIndex

        func emit(_ end: String.Index) {
            guard sliceStart < end else { sliceStart = end; return }
            let spoken = speechTransform(String(text[sliceStart..<end]))
            if !spoken.isEmpty {
                let local = NSRange(sliceStart..<end, in: text)
                result.append(DisplayChunk(
                    displayRange: NSRange(location: range.location + local.location, length: local.length),
                    spoken: spoken
                ))
            }
            sliceStart = end
        }

        while index < text.endIndex {
            if text[index] == " " { lastSpace = index }
            let next = text.index(after: index)
            if text.distance(from: sliceStart, to: next) >= maxChunkLength {
                let breakPoint = (lastSpace.flatMap { $0 > sliceStart ? text.index(after: $0) : nil }) ?? next
                emit(breakPoint)
                lastSpace = nil
                index = breakPoint
            } else {
                index = next
            }
        }
        if sliceStart < text.endIndex { emit(text.endIndex) }
        return result
    }

    /// Collapse all whitespace (newlines, tabs, repeated spaces) into single spaces.
    static func normalize(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Split on sentence-ending punctuation, keeping the punctuation.
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if char == "." || char == "!" || char == "?" || char == ";" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }

    /// Word-boundary split for a single overlong sentence.
    private static func hardSplit(_ sentence: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in sentence.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= maxChunkLength {
                current += " " + word
            } else {
                chunks.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
