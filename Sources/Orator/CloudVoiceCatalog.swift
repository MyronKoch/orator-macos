import Foundation

/// A Cloudflare Workers AI text-to-speech model Orator can call.
///
/// All three are Cloudflare-HOSTED (billed as Workers AI neurons), reached
/// through the same `POST /accounts/{id}/ai/run/{modelID}` endpoint. MeloTTS is
/// effectively free within the daily neuron allowance; Aura-1/Aura-2 cost per
/// character (which is WHY the `CloudUsageMeter` exists from day one).
enum CloudModel: String, Sendable, CaseIterable {
    case melotts
    case aura1
    case aura2

    /// The Workers AI model id used in the run endpoint path.
    var modelID: String {
        switch self {
        case .melotts: return "@cf/myshell-ai/melotts"
        case .aura1: return "@cf/deepgram/aura-1"
        case .aura2: return "@cf/deepgram/aura-2-en"
        }
    }

    /// The `cf:<key>:...` namespace segment and picker group label.
    var key: String {
        switch self {
        case .melotts: return "melotts"
        case .aura1: return "aura-1"
        case .aura2: return "aura-2"
        }
    }

    var groupName: String {
        switch self {
        case .melotts: return "MeloTTS (cloud)"
        case .aura1: return "Deepgram Aura-1 (cloud)"
        case .aura2: return "Deepgram Aura-2 (cloud)"
        }
    }

    /// Free within the daily Workers AI neuron allowance. Aura bills per
    /// character; MeloTTS is effectively free. Surfaced so the UI can label
    /// paid voices and the meter can weight them.
    var isEffectivelyFree: Bool { self == .melotts }
}

/// One selectable cloud voice. `id` is namespaced `cf:<model.key>:<speaker>`
/// (e.g. `cf:aura-2:thalia`), so it coexists with Kokoro/Kitten/Piper voices in
/// the one picker and saved preference.
struct CloudVoice: Sendable {
    let id: String
    let displayName: String
    let model: CloudModel
    /// Deepgram speaker name; nil for MeloTTS (which has no speaker parameter).
    let speaker: String?

    /// The JSON body for this model's Workers AI run call. Aura returns mp3 we
    /// decode + resample to 24 kHz; MeloTTS returns mp3 as well.
    func requestBody(text: String) -> [String: Any] {
        switch model {
        case .melotts:
            return ["prompt": text, "lang": "en"]
        case .aura1, .aura2:
            return ["text": text, "speaker": speaker ?? "", "encoding": "mp3"]
        }
    }
}

/// The static catalog of Cloudflare voices. Cloud voices need no download - they
/// are always "available" given credentials + network - so unlike the on-device
/// `VoiceCatalog` there is no install step here.
enum CloudVoiceCatalog {
    /// Deepgram Aura-1 speakers (verified against the Cloudflare model schema).
    private static let aura1Speakers = [
        "angus", "asteria", "arcas", "orion", "orpheus", "athena",
        "luna", "zeus", "perseus", "helios", "hera", "stella",
    ]

    /// Deepgram Aura-2 English speakers (verified against the Cloudflare model
    /// schema). Genders are deliberately NOT labeled - unverified; Myron tags by
    /// ear. Add gender suffixes once confirmed from Deepgram's voice list.
    private static let aura2Speakers = [
        "amalthea", "andromeda", "apollo", "arcas", "aries", "asteria",
        "athena", "atlas", "aurora", "callista", "cora", "cordelia", "delia",
        "draco", "electra", "harmonia", "helena", "hera", "hermes", "hyperion",
        "iris", "janus", "juno", "jupiter", "luna", "mars", "minerva", "neptune",
        "odysseus", "ophelia", "orion", "orpheus", "pandora", "phoebe", "pluto",
        "saturn", "thalia", "theia", "vesta", "zeus",
    ]

    static let voices: [CloudVoice] = {
        var all: [CloudVoice] = [
            CloudVoice(
                id: VoiceInfo.namespaced(provider: "cf", local: "\(CloudModel.melotts.key):en"),
                displayName: "MeloTTS English",
                model: .melotts,
                speaker: nil
            )
        ]
        all += aura1Speakers.map { speaker in
            CloudVoice(
                id: VoiceInfo.namespaced(provider: "cf", local: "\(CloudModel.aura1.key):\(speaker)"),
                displayName: speaker.capitalized,
                model: .aura1,
                speaker: speaker
            )
        }
        all += aura2Speakers.map { speaker in
            CloudVoice(
                id: VoiceInfo.namespaced(provider: "cf", local: "\(CloudModel.aura2.key):\(speaker)"),
                displayName: speaker.capitalized,
                model: .aura2,
                speaker: speaker
            )
        }
        return all
    }()

    private static let byID: [String: CloudVoice] = Dictionary(
        uniqueKeysWithValues: voices.map { ($0.id, $0) }
    )

    static func voice(for voiceID: String) -> CloudVoice? { byID[voiceID] }

    static var voiceInfos: [VoiceInfo] {
        voices.map { voice in
            VoiceInfo(
                id: voice.id,
                displayName: voice.displayName,
                provider: "cf",
                language: "en",
                supportsWordTimings: false
            )
        }
    }
}
