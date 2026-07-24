import Foundation

enum ScriptCaster {
    struct Options: Sendable {
        var readSceneHeadings = false
        var readParentheticals = false
        var readTransitions = false
    }

    static func cast(
        elements: [ScriptElement],
        cast: ScriptCast,
        options: Options = Options()
    ) -> [SpeechSegment] {
        var speaker: String?
        var segments: [SpeechSegment] = []

        for element in elements {
            switch element {
            case .characterCue(let name):
                speaker = name
            case .dialogue(let text):
                guard let speaker, let voice = cast.characterVoices[speaker] else { continue }
                append(text, voice: voice, to: &segments)
            case .action(let text):
                speaker = nil
                append(text, voice: cast.narratorVoice, to: &segments)
            case .sceneHeading(let text):
                speaker = nil
                if options.readSceneHeadings { append(text, voice: cast.narratorVoice, to: &segments) }
            case .parenthetical(let text):
                if options.readParentheticals { append(text, voice: cast.narratorVoice, to: &segments) }
            case .transition(let text):
                speaker = nil
                if options.readTransitions { append(text, voice: cast.narratorVoice, to: &segments) }
            }
        }
        return segments
    }

    private static func append(_ text: String, voice: String, to segments: inout [SpeechSegment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !voice.isEmpty else { return }
        if let last = segments.last, last.voiceName == voice {
            segments[segments.count - 1] = SpeechSegment(
                text: last.text + "\n" + trimmed,
                voiceName: voice
            )
        } else {
            segments.append(SpeechSegment(text: trimmed, voiceName: voice))
        }
    }
}
