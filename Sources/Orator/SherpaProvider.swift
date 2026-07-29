import Foundation

/// KittenTTS behind the `TTSProvider` seam, backed by sherpa-onnx.
///
/// The model is loaded from a local directory. Kitten does not report word
/// timings.
final class SherpaProvider: TTSProvider, @unchecked Sendable {

    let id = "kitten"
    var sampleRate: Double { Double(tts.sampleRate) }

    private let tts: SherpaOnnxOfflineTtsWrapper
    private let inferenceLock = NSLock()

    init(modelDir: URL) throws {
        let kitten = sherpaOnnxOfflineTtsKittenModelConfig(
            model: modelDir.appendingPathComponent("model.onnx").path,
            voices: modelDir.appendingPathComponent("voices.bin").path,
            tokens: modelDir.appendingPathComponent("tokens.txt").path,
            dataDir: modelDir.appendingPathComponent("espeak-ng-data").path
        )
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(debug: 0, kitten: kitten)
        var ttsConfig = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let tts = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)
        guard tts.tts != nil else {
            throw OratorError.providerNotReady(
                "KittenTTS model failed to load at \(modelDir.path)"
            )
        }
        self.tts = tts
    }

    func voices() -> [VoiceInfo] {
        // sid -> name is VERIFIED (F0 fingerprint matched to the KittenTTS
        // reference voices, plus by-ear confirmation). sherpa preserves the
        // upstream `available_voices` row order, but KittenTTS's friendly names
        // are assigned with each adjacent voice pair swapped, so the order below
        // is NOT the KittenTTS all_voice_names order. Measured F0 (Hz), for
        // reference: Jasper 171, Bella 222, Bruno 112 (the one clearly male),
        // Luna 211, Hugo 175, Rosie 221, Leo 202, Kiki 250.
        let displayNames = [
            "Jasper (F)", "Bella (F)", "Bruno (M)", "Luna (F)",
            "Hugo (M)", "Rosie (F)", "Leo (F)", "Kiki (F)",
        ]
        return displayNames.enumerated().map { sid, displayName in
            VoiceInfo(
                id: VoiceInfo.namespaced(provider: id, local: String(sid)),
                displayName: displayName,
                provider: id,
                language: "en",
                supportsWordTimings: false
            )
        }
    }

    func canSpeak(voiceID: String) -> Bool {
        guard let sid = Int(VoiceInfo.localID(of: voiceID)) else { return false }
        return (0..<Int(tts.numSpeakers)).contains(sid)
    }

    func synthesize(text: String, voiceID: String, speed: Float) throws -> TTSSynthesis {
        let sid = Int(VoiceInfo.localID(of: voiceID)) ?? 0
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        let audio = tts.generate(text: text, sid: sid, speed: speed)
        // sherpa-onnx does not expose word timings for KittenTTS.
        return TTSSynthesis(samples: audio.samples, words: nil)
    }

    /// Force one tiny synthesis so the first real utterance has no warmup lag.
    func warmUp() {
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        _ = tts.generate(text: "Hi.", sid: 0, speed: 1.0)
    }
}
