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
                append(text, voice: voice, speaker: speaker, to: &segments)
            case .action(let text):
                speaker = nil
                append(text, voice: cast.narratorVoice, speaker: nil, to: &segments)
            case .sceneHeading(let text):
                speaker = nil
                if options.readSceneHeadings {
                    append(text, voice: cast.narratorVoice, speaker: nil, to: &segments)
                }
            case .parenthetical(let text):
                if options.readParentheticals {
                    append(text, voice: cast.narratorVoice, speaker: speaker, to: &segments)
                }
            case .transition(let text):
                speaker = nil
                if options.readTransitions {
                    append(text, voice: cast.narratorVoice, speaker: nil, to: &segments)
                }
            }
        }
        return segments
    }

    private static func append(
        _ text: String,
        voice: String,
        speaker: String?,
        to segments: inout [SpeechSegment]
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !voice.isEmpty else { return }
        // Merge only when the SPEAKER matches too, not just the voice. Two
        // characters sharing one voice must stay separate segments or they would
        // collapse into a single mislabelled clip on the timeline.
        if let last = segments.last, last.voiceName == voice, last.speaker == speaker {
            segments[segments.count - 1] = SpeechSegment(
                text: last.text + "\n" + trimmed,
                voiceName: voice,
                speed: last.speed,
                speaker: speaker
            )
        } else {
            segments.append(SpeechSegment(text: trimmed, voiceName: voice, speaker: speaker))
        }
    }
}
