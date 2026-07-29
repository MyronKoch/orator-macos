import Foundation

/// KittenTTS behind the `TTSProvider` seam, backed by sherpa-onnx.
///
/// The model is loaded from a local directory. Download-on-demand support will
/// be added later. Kitten does not report word timings, and its speaker-id to
/// display-name mapping is tentative pending by-ear verification.
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
        // TENTATIVE: The sid-to-name mapping needs by-ear verification.
        let displayNames = [
            "Bella", "Jasper", "Luna", "Bruno",
            "Rosie", "Hugo", "Kiki", "Leo",
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
