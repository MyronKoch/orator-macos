import Foundation

/// Builds a screenplay-laid-out Reader document from parsed script elements.
///
/// The Reader has always been able to show one thing and speak another - that
/// is how `TextChunker.readerChunks` keeps source formatting. Script mode
/// simply predates it and went through the flat `chunks.joined(separator: " ")`
/// path, which is why a table read rendered as a wall of prose with the
/// character cues and scene headings dissolved into it.
///
/// This produces the same contract `readerChunks` does - a display string plus
/// per-chunk spoken text and exact display ranges - and adds two things script
/// mode needs: the voice for each chunk, and a block map so the window can
/// indent cues and dialogue like a screenplay.
///
/// The display/spoken split is exactly right for a script: cues, headings, and
/// skipped elements stay VISIBLE while remaining silent.
enum ScriptFormatter {

    enum BlockKind {
        case sceneHeading
        case action
        case characterCue
        case parenthetical
        case dialogue
        case transition
    }

    struct Block {
        let range: NSRange
        let kind: BlockKind
    }

    struct Document {
        let display: String
        /// Spoken text + its exact range in `display`, in playback order.
        let chunks: [TextChunker.DisplayChunk]
        /// Voice for each chunk, parallel to `chunks`.
        let voices: [String]
        /// Effective speaking rate for each chunk, parallel to `chunks`.
        let speeds: [Float]
        let blocks: [Block]

        var isEmpty: Bool { chunks.isEmpty }

        /// One segment per chunk. Deliberately NOT merged by voice: the engine
        /// re-chunks every segment through `TextChunker.chunk`, and a string
        /// that is already a chunk re-chunks to itself, so chunk indices stay
        /// aligned with `chunks` and the highlight cannot drift. Merging would
        /// let the chunker re-pack across these boundaries.
        var segments: [SpeechSegment] {
            chunks.indices.map { index in
                SpeechSegment(
                    text: chunks[index].spoken,
                    voiceName: voices[index],
                    speed: speeds[index]
                )
            }
        }
    }

    static func format(
        elements: [ScriptElement],
        cast: ScriptCast,
        options: ScriptCaster.Options = ScriptCaster.Options()
    ) -> Document {
        var display = ""
        var utf16Offset = 0
        var chunks: [TextChunker.DisplayChunk] = []
        var voices: [String] = []
        var speeds: [Float] = []
        var blocks: [Block] = []
        var speaker: String?

        /// Append one block of display text, optionally making it speakable.
        /// Returns nothing; everything accumulates.
        func append(_ text: String, kind: BlockKind, voice: String?, speed: Float = 1.0) {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }

            if !display.isEmpty {
                // Blank line between blocks, as in a real screenplay.
                display += "\n\n"
                utf16Offset += 2
            }

            if let voice, !voice.isEmpty {
                // Reuse the Reader's own display/spoken splitter so the ranges
                // are produced by the same tested code path, then shift them
                // into this document's coordinate space.
                let unit = TextChunker.readerChunks(body)
                let rendered = unit.display.isEmpty ? body : unit.display
                display += rendered
                for chunk in unit.chunks {
                    chunks.append(TextChunker.DisplayChunk(
                        displayRange: NSRange(
                            location: chunk.displayRange.location + utf16Offset,
                            length: chunk.displayRange.length
                        ),
                        spoken: chunk.spoken
                    ))
                    voices.append(voice)
                    speeds.append(speed)
                }
                blocks.append(Block(
                    range: NSRange(location: utf16Offset, length: rendered.utf16.count),
                    kind: kind
                ))
                utf16Offset += rendered.utf16.count
            } else {
                // Visible but silent: character cues, and anything the skip
                // options exclude. Still laid out, still readable.
                display += body
                blocks.append(Block(
                    range: NSRange(location: utf16Offset, length: body.utf16.count),
                    kind: kind
                ))
                utf16Offset += body.utf16.count
            }
        }

        for element in elements {
            switch element {
            case .characterCue(let name):
                speaker = name
                // Always shown, never spoken - you want to see who is talking.
                append(name, kind: .characterCue, voice: nil)

            case .dialogue(let text):
                let voice = speaker.flatMap { cast.characterVoices[$0] }
                append(
                    text,
                    kind: .dialogue,
                    voice: voice,
                    speed: speaker.map { cast.effectiveSpeed(forCharacter: $0) }
                        ?? cast.effectiveNarratorSpeed
                )

            case .action(let text):
                speaker = nil
                append(
                    text, kind: .action,
                    voice: cast.narratorVoice, speed: cast.effectiveNarratorSpeed
                )

            case .sceneHeading(let text):
                speaker = nil
                append(
                    text,
                    kind: .sceneHeading,
                    voice: options.readSceneHeadings ? cast.narratorVoice : nil,
                    speed: cast.effectiveNarratorSpeed
                )

            case .parenthetical(let text):
                append(
                    text,
                    kind: .parenthetical,
                    voice: options.readParentheticals ? cast.narratorVoice : nil,
                    speed: cast.effectiveNarratorSpeed
                )

            case .transition(let text):
                speaker = nil
                append(
                    text,
                    kind: .transition,
                    voice: options.readTransitions ? cast.narratorVoice : nil,
                    speed: cast.effectiveNarratorSpeed
                )
            }
        }

        return Document(
            display: display, chunks: chunks, voices: voices, speeds: speeds, blocks: blocks
        )
    }
}
