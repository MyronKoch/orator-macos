import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

/// Kokoro-82M behind the `TTSProvider` seam.
///
/// This owns everything Kokoro-specific that used to live in `OratorEngine`:
/// the model handle, the voice-embedding table, the en-GB/en-US selection, and
/// the `MToken` -> `WordTiming` conversion. `OratorEngine` keeps the playback
/// state machine and now only asks for samples.
final class KokoroProvider: TTSProvider, @unchecked Sendable {

    let id = "kokoro"
    var sampleRate: Double { Double(KokoroTTS.Constants.samplingRate) }

    private let tts: KokoroTTS
    private let embeddings: [String: MLXArray]

    init(modelPath: URL, voicesPath: URL) throws {
        // MLX memory limits live here rather than in OratorEngine: MLX is an
        // implementation detail of THIS provider, not of playback.
        GPU.set(cacheLimit: 50 * 1024 * 1024)
        GPU.set(memoryLimit: 900 * 1024 * 1024)

        tts = KokoroTTS(modelPath: modelPath)
        guard let loaded = NpyzReader.read(fileFromPath: voicesPath) else {
            throw OratorError.voicesNotFound
        }
        embeddings = loaded
        oratorLog(
            "kokoro provider: loaded \(loaded.count) voices, sample keys: "
            + "\(Array(loaded.keys.sorted().prefix(3)))"
        )
    }

    func voices() -> [VoiceInfo] {
        embeddings.keys
            .map { $0.replacingOccurrences(of: ".npy", with: "") }
            .sorted()
            .map { local in
                VoiceInfo(
                    id: VoiceInfo.namespaced(provider: id, local: local),
                    displayName: local,
                    provider: id,
                    // Kokoro's "b" prefix marks the British English voices.
                    language: local.hasPrefix("b") ? "en-GB" : "en-US",
                    supportsWordTimings: true
                )
            }
    }

    /// Bare local voice names, as the app's existing pickers and prefs use them.
    var localVoiceNames: [String] {
        embeddings.keys.map { $0.replacingOccurrences(of: ".npy", with: "") }.sorted()
    }

    func canSpeak(voiceID: String) -> Bool {
        embedding(for: VoiceInfo.localID(of: voiceID)) != nil
    }

    func synthesize(text: String, voiceID: String, speed: Float) throws -> TTSSynthesis {
        let local = VoiceInfo.localID(of: voiceID)
        guard let voice = embedding(for: local) else {
            throw OratorError.voiceNotFound(local)
        }
        let (samples, tokens) = try tts.generateAudio(
            voice: voice,
            language: language(for: local),
            text: text,
            speed: speed
        )
        return TTSSynthesis(samples: samples, words: tokens.map(Self.wordTimings))
    }

    /// Force one tiny synthesis so the first real utterance has no warmup lag.
    func warmUp(voiceID: String) {
        let local = VoiceInfo.localID(of: voiceID)
        guard let voice = embedding(for: local) ?? embeddings.values.first else { return }
        _ = try? tts.generateAudio(voice: voice, language: .enUS, text: "Hi.", speed: 1.0)
    }

    /// Return MLX's cached buffers to the OS. Call AFTER releasing the last
    /// KokoroProvider so the ~380 MB the model held is actually reclaimed
    /// (verified: release + clearCache drops RSS ~380 MB). Deallocating the
    /// provider alone leaves the memory in MLX's pool.
    static func releaseCachedMemory() {
        GPU.clearCache()
    }

    // MARK: - Kokoro specifics

    /// Resolve a voice name to its embedding, tolerating suffix-spelling
    /// variants in the bundled `voices.npz`.
    private func embedding(for voiceName: String) -> MLXArray? {
        embeddings[voiceName + ".npy"]
            ?? embeddings[voiceName]
            ?? embeddings[voiceName + ".npy.npy"]
    }

    private func language(for voiceName: String) -> Language {
        voiceName.hasPrefix("b") ? .enGB : .enUS
    }

    private static func wordTimings(_ tokens: [MToken]) -> [WordTiming] {
        tokens.map {
            WordTiming(
                text: $0.text,
                whitespace: $0.whitespace,
                start: $0.start_ts,
                end: $0.end_ts
            )
        }
    }
}
