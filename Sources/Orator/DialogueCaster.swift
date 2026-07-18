import Foundation

/// Heuristically separates narration from quoted dialogue and assigns a
/// consistent, region-compatible voice to each detected speaker.
enum DialogueCaster {

    private enum QuoteKind {
        case straight
        case curly
    }

    private enum Gender {
        case female
        case male
    }

    private enum Attribution {
        case name(String)
        case pronoun(String)
    }

    private struct QuoteSpan {
        let range: Range<String.Index>
    }

    private struct CastDialogue {
        let span: QuoteSpan
        let speaker: String
        let gender: Gender?
    }

    private struct AttributionMatch {
        let attribution: Attribution
        let range: NSRange
    }

    private static let speechVerbs =
        "said|asked|replied|answered|whispered|shouted|murmured|cried|added|continued|began|muttered|exclaimed"

    private static let attributionPatterns: [NSRegularExpression] = {
        let entity = #"([\p{Lu}][\p{L}\p{M}'’-]*|[Hh]e|[Ss]he|[Tt]hey|I)"#
        let verb = "(?i:\(speechVerbs))"
        return [
            try! NSRegularExpression(pattern: "\\b\(entity)\\s+\(verb)\\b"),
            try! NSRegularExpression(pattern: "\\b\(verb)\\s+\(entity)\\b"),
        ]
    }()

    private static let maleNames: Set<String> = [
        "adam", "alexander", "andrew", "anthony", "ben", "benjamin",
        "charles", "daniel", "david", "edward", "ethan", "frank", "george",
        "henry", "jack", "james", "john", "joseph", "liam", "mark",
        "michael", "noah", "oliver", "peter", "robert", "samuel", "thomas",
        "william",
    ]

    private static let femaleNames: Set<String> = [
        "alice", "amelia", "anna", "ava", "bella", "charlotte", "claire",
        "elizabeth", "emily", "emma", "grace", "hannah", "isabella", "jane",
        "jessica", "julia", "lily", "mary", "mia", "nicole", "olivia",
        "rachel", "sarah", "sophia", "victoria",
    ]

    /// Split text into ordered narration/dialogue segments and assign voices.
    /// The same speaker label always receives the same voice within one call.
    static func cast(
        text: String,
        narratorVoice: String,
        pool: [String]
    ) -> [SpeechSegment] {
        let quoteSpans = findDialogueSpans(in: text)
        guard !quoteSpans.isEmpty else {
            return [SpeechSegment(text: text, voiceName: narratorVoice)]
        }

        var recentSpeakers: [String] = []
        var recentNamedSpeakers: [String] = []
        var knownGenders: [String: Gender] = [:]
        var castDialogues: [CastDialogue] = []
        castDialogues.reserveCapacity(quoteSpans.count)

        for (index, span) in quoteSpans.enumerated() {
            let beforeStart = index == 0
                ? text.startIndex
                : quoteSpans[index - 1].range.upperBound
            let afterEnd = index + 1 < quoteSpans.count
                ? quoteSpans[index + 1].range.lowerBound
                : text.endIndex

            let before = attributionContextBefore(
                text[beforeStart..<span.range.lowerBound]
            )
            let after = attributionContextAfter(
                text[span.range.upperBound..<afterEnd]
            )
            let beforeAttribution = findAttribution(in: before, nearestToStart: false)
            let afterAttribution = findAttribution(in: after, nearestToStart: true)
            let attribution: Attribution?
            if index + 1 < quoteSpans.count,
               !after.contains(where: isSentenceEnd),
               let beforeAttribution {
                // An after-context tag ending immediately before the next
                // opening quote normally introduces that next line. Prefer
                // this line's own pre-attribution when it has one.
                attribution = beforeAttribution
            } else {
                attribution = afterAttribution ?? beforeAttribution
            }

            let speaker: String
            var inferredGender: Gender?
            switch attribution {
            case .name(let name):
                speaker = name.lowercased()
                inferredGender = gender(forName: name)
                if let inferredGender {
                    knownGenders[speaker] = inferredGender
                }
                noteRecent(speaker, in: &recentNamedSpeakers)

            case .pronoun(let pronoun):
                switch pronoun.lowercased() {
                case "he":
                    inferredGender = .male
                    speaker = recentNamedSpeakers.first {
                        knownGenders[$0] == .male
                    } ?? "__he"
                case "she":
                    inferredGender = .female
                    speaker = recentNamedSpeakers.first {
                        knownGenders[$0] == .female
                    } ?? "__she"
                case "they":
                    speaker = recentSpeakers.first ?? "__they"
                    inferredGender = knownGenders[speaker]
                default: // I
                    speaker = recentSpeakers.first ?? "__i"
                    inferredGender = knownGenders[speaker]
                }

                if !speaker.hasPrefix("__") {
                    noteRecent(speaker, in: &recentNamedSpeakers)
                }
                if let inferredGender {
                    knownGenders[speaker] = inferredGender
                }

            case nil:
                if recentSpeakers.count >= 2 {
                    speaker = recentSpeakers[1]
                } else {
                    speaker = recentSpeakers.first ?? "__spk1"
                }
                inferredGender = knownGenders[speaker]
            }

            noteRecent(speaker, in: &recentSpeakers)
            castDialogues.append(CastDialogue(
                span: span,
                speaker: speaker,
                gender: inferredGender ?? knownGenders[speaker]
            ))
        }

        var voiceAllocator = VoiceAllocator(
            narratorVoice: narratorVoice,
            availableVoices: pool
        )
        var segments: [SpeechSegment] = []
        var cursor = text.startIndex

        for dialogue in castDialogues {
            appendIfSpeakable(
                text[cursor..<dialogue.span.range.lowerBound],
                voice: narratorVoice,
                to: &segments
            )
            appendIfSpeakable(
                text[dialogue.span.range],
                voice: voiceAllocator.voice(
                    for: dialogue.speaker,
                    gender: dialogue.gender
                ),
                to: &segments
            )
            cursor = dialogue.span.range.upperBound
        }

        appendIfSpeakable(
            text[cursor..<text.endIndex],
            voice: narratorVoice,
            to: &segments
        )
        return segments
    }

    private static func findDialogueSpans(in text: String) -> [QuoteSpan] {
        var spans: [QuoteSpan] = []
        var opening: (index: String.Index, kind: QuoteKind)?

        for index in text.indices {
            let character = text[index]
            if let active = opening {
                let closesActiveQuote = (active.kind == .straight && character == "\"")
                    || (active.kind == .curly && character == "”")
                guard closesActiveQuote else { continue }

                let contentStart = text.index(after: active.index)
                let content = text[contentStart..<index]
                if content.contains(where: { !$0.isWhitespace }) {
                    spans.append(QuoteSpan(
                        range: active.index..<text.index(after: index)
                    ))
                }
                opening = nil
            } else if character == "\"" {
                opening = (index, .straight)
            } else if character == "“" {
                opening = (index, .curly)
            }
        }

        // An unmatched opening quote is deliberately ignored. Since spans are
        // only recorded when closed, its remainder stays in narration.
        return spans
    }

    private static func attributionContextAfter(_ text: Substring) -> String {
        var result = ""
        for character in text.prefix(48) {
            result.append(character)
            if isSentenceEnd(character) { break }
        }
        return result
    }

    private static func attributionContextBefore(_ text: Substring) -> String {
        let suffix = String(text.suffix(48))
        guard let sentenceEnd = suffix.lastIndex(where: isSentenceEnd) else {
            return suffix
        }
        return String(suffix[suffix.index(after: sentenceEnd)...])
    }

    private static func isSentenceEnd(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character == ";"
    }

    private static func findAttribution(
        in context: String,
        nearestToStart: Bool
    ) -> Attribution? {
        let searchRange = NSRange(context.startIndex..<context.endIndex, in: context)
        var matches: [AttributionMatch] = []

        for expression in attributionPatterns {
            for match in expression.matches(in: context, range: searchRange) {
                guard match.numberOfRanges > 1,
                      let entityRange = Range(match.range(at: 1), in: context)
                else { continue }

                let entity = String(context[entityRange])
                let lowered = entity.lowercased()
                let attribution: Attribution
                if lowered == "he" || lowered == "she" || lowered == "they" || entity == "I" {
                    attribution = .pronoun(lowered)
                } else {
                    attribution = .name(entity)
                }
                matches.append(AttributionMatch(
                    attribution: attribution,
                    range: match.range
                ))
            }
        }

        let selected = matches.min { lhs, rhs in
            if nearestToStart {
                return lhs.range.location < rhs.range.location
            }
            return NSMaxRange(lhs.range) > NSMaxRange(rhs.range)
        }
        return selected?.attribution
    }

    private static func gender(forName name: String) -> Gender? {
        let firstName = name
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased() ?? name.lowercased()
        if maleNames.contains(firstName) { return .male }
        if femaleNames.contains(firstName) { return .female }
        return nil
    }

    private static func noteRecent(_ speaker: String, in speakers: inout [String]) {
        speakers.removeAll { $0 == speaker }
        speakers.insert(speaker, at: 0)
    }

    private static func appendIfSpeakable(
        _ text: Substring,
        voice: String,
        to segments: inout [SpeechSegment]
    ) {
        guard text.contains(where: { !$0.isWhitespace }) else { return }
        segments.append(SpeechSegment(text: String(text), voiceName: voice))
    }

    private struct VoiceAllocator {
        let narratorVoice: String
        let voices: [String]
        var assigned: [String: String] = [:]
        var used: Set<String> = []

        init(narratorVoice: String, availableVoices: [String]) {
            self.narratorVoice = narratorVoice

            guard let region = narratorVoice.first, region == "a" || region == "b" else {
                voices = []
                return
            }

            let malePrefix = "\(region)m_"
            let femalePrefix = "\(region)f_"
            let compatible = Set(availableVoices.filter {
                $0 != narratorVoice
                    && ($0.hasPrefix(malePrefix) || $0.hasPrefix(femalePrefix))
            })
            let male = compatible.filter { $0.hasPrefix(malePrefix) }.sorted()
            let female = compatible.filter { $0.hasPrefix(femalePrefix) }.sorted()

            var alternated: [String] = []
            alternated.reserveCapacity(compatible.count)
            let count = max(male.count, female.count)
            for index in 0..<count {
                if male.indices.contains(index) { alternated.append(male[index]) }
                if female.indices.contains(index) { alternated.append(female[index]) }
            }
            voices = alternated
        }

        mutating func voice(for speaker: String, gender: Gender?) -> String {
            if let existing = assigned[speaker] { return existing }
            guard !voices.isEmpty else {
                assigned[speaker] = narratorVoice
                return narratorVoice
            }

            let preferredPrefix: String?
            switch gender {
            case .female: preferredPrefix = "f_"
            case .male: preferredPrefix = "m_"
            case nil: preferredPrefix = nil
            }

            let unusedPreferredVoice = preferredPrefix.flatMap { prefix in
                voices.first { voice in
                    !used.contains(voice) && voice.dropFirst().hasPrefix(prefix)
                }
            }
            let unusedVoice = unusedPreferredVoice ?? voices.first { !used.contains($0) }

            let selected = unusedVoice
                ?? voices[Int(stableHash(speaker) % UInt64(voices.count))]
            assigned[speaker] = selected
            used.insert(selected)
            return selected
        }

        private func stableHash(_ value: String) -> UInt64 {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            return hash
        }
    }
}
