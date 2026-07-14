import Foundation

/// Splits arbitrary selected text into TTS-sized chunks.
///
/// KokoroTTS rejects inputs over 510 phoneme tokens. Phoneme count roughly
/// tracks character count, so we pack sentences into chunks capped well below
/// that ceiling. Sentence boundaries keep prosody natural; a hard word-split
/// fallback handles pathological run-on text.
enum TextChunker {

    static let maxChunkLength = 350

    /// Normalize whitespace/newlines, then split into speakable chunks.
    static func chunk(_ raw: String) -> [String] {
        var text = normalize(ReadableText.clean(raw))
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
