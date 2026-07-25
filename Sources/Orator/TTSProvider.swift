import Foundation

/// One voice a provider can speak with.
///
/// `id` is NAMESPACED (`"kokoro:af_heart"`, `"apple:com.apple.voice.premium.en-US.Ava"`)
/// so voices from different engines can coexist in one picker and one saved
/// preference without colliding.
struct VoiceInfo: Sendable, Hashable {
    let id: String
    let displayName: String
    let provider: String
    let language: String
    let supportsWordTimings: Bool

    /// The provider half of a namespaced id (`"kokoro:af_heart"` -> `"kokoro"`).
    /// Returns nil for a bare, un-namespaced name.
    static func providerID(of voiceID: String) -> String? {
        guard let separator = voiceID.firstIndex(of: ":") else { return nil }
        return String(voiceID[voiceID.startIndex..<separator])
    }

    /// The engine-local half (`"kokoro:af_heart"` -> `"af_heart"`). A bare name
    /// is returned unchanged, which is what makes migration of old saved prefs
    /// a no-op rather than a breaking change.
    static func localID(of voiceID: String) -> String {
        guard let separator = voiceID.firstIndex(of: ":") else { return voiceID }
        return String(voiceID[voiceID.index(after: separator)...])
    }

    static func namespaced(provider: String, local: String) -> String {
        "\(provider):\(local)"
    }
}

/// PCM plus optional per-word timings for one synthesized chunk.
struct TTSSynthesis: Sendable {
    let samples: [Float]
    /// Chunk-relative word timings, or nil when the engine cannot report them.
    /// A nil here costs the Reader its per-word highlight for that chunk but
    /// does not affect playback.
    let words: [WordTiming]?
}

/// A local speech engine that turns text into PCM samples.
///
/// The whole point of this seam: everything downstream of synthesis - the
/// `AVAudioPlayerNode` scheduling, pause/resume, the reading queue, and the
/// Reader's follow-along highlight - already operates on `[Float]` PCM rather
/// than on any particular engine. So a new engine only has to SUPPLY samples at
/// the engine's sample rate. `OratorEngine`'s guarded concurrency core keeps
/// sole ownership of scheduling, cancellation, and playback state.
///
/// Providers must be safe to call from `OratorEngine`'s synthesis queue.
protocol TTSProvider: Sendable {
    /// Short, stable identifier used as the voice-id namespace ("kokoro").
    var id: String { get }

    /// Sample rate of the PCM this provider returns. Must match the audio
    /// engine's format, or the caller has to convert before scheduling -
    /// scheduling at the wrong rate yields chipmunk/garbled audio.
    var sampleRate: Double { get }

    func voices() -> [VoiceInfo]

    /// True when this provider can speak `voiceID` (namespaced or bare).
    func canSpeak(voiceID: String) -> Bool

    /// Synthesize one chunk. Called off the main thread, once per chunk, and
    /// may be invoked repeatedly for a single utterance.
    func synthesize(text: String, voiceID: String, speed: Float) throws -> TTSSynthesis
}
