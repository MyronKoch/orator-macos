import Foundation
import SherpaOnnxC  // C config types (SherpaOnnxOfflineTtsModelConfig) from the xcframework

enum SherpaModelKind {
    case kitten
    case vits
}

struct SherpaVoice {
    let localID: String
    let sid: Int
    let displayName: String
}

/// A sherpa-onnx model behind the `TTSProvider` seam.
///
/// The model is loaded from a local directory. Sherpa does not report word
/// timings.
final class SherpaProvider: TTSProvider, @unchecked Sendable {

    let id: String
    var sampleRate: Double { Double(tts.sampleRate) }

    private let tts: SherpaOnnxOfflineTtsWrapper
    private let modelVoices: [SherpaVoice]
    private let inferenceLock = NSLock()

    init(
        id: String,
        modelDir: URL,
        kind: SherpaModelKind,
        voices: [SherpaVoice]
    ) throws {
        let modelConfig: SherpaOnnxOfflineTtsModelConfig
        switch kind {
        case .kitten:
            let kitten = sherpaOnnxOfflineTtsKittenModelConfig(
                model: modelDir.appendingPathComponent("model.onnx").path,
                voices: modelDir.appendingPathComponent("voices.bin").path,
                tokens: modelDir.appendingPathComponent("tokens.txt").path,
                dataDir: modelDir.appendingPathComponent("espeak-ng-data").path
            )
            modelConfig = sherpaOnnxOfflineTtsModelConfig(debug: 0, kitten: kitten)
        case .vits:
            let contents = try FileManager.default.contentsOfDirectory(
                at: modelDir,
                includingPropertiesForKeys: nil
            )
            guard let model = contents.first(where: { $0.path.hasSuffix(".onnx") }) else {
                throw OratorError.providerNotReady(
                    "VITS model not found at \(modelDir.path)"
                )
            }
            let vits = sherpaOnnxOfflineTtsVitsModelConfig(
                model: model.path,
                lexicon: "",
                tokens: modelDir.appendingPathComponent("tokens.txt").path,
                dataDir: modelDir.appendingPathComponent("espeak-ng-data").path
            )
            modelConfig = sherpaOnnxOfflineTtsModelConfig(vits: vits)
        }

        var ttsConfig = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let tts = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)
        guard tts.tts != nil else {
            throw OratorError.providerNotReady(
                "\(id) model failed to load at \(modelDir.path)"
            )
        }
        self.id = id
        self.tts = tts
        self.modelVoices = voices
    }

    func voices() -> [VoiceInfo] {
        modelVoices.map { voice in
            VoiceInfo(
                id: VoiceInfo.namespaced(provider: id, local: voice.localID),
                displayName: voice.displayName,
                provider: id,
                language: "en",
                supportsWordTimings: false
            )
        }
    }

    func canSpeak(voiceID: String) -> Bool {
        let localID = VoiceInfo.localID(of: voiceID)
        return modelVoices.contains(where: { $0.localID == localID })
    }

    func synthesize(text: String, voiceID: String, speed: Float) throws -> TTSSynthesis {
        let localID = VoiceInfo.localID(of: voiceID)
        guard let voice = modelVoices.first(where: { $0.localID == localID }) else {
            throw OratorError.voiceNotFound(localID)
        }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        let audio = tts.generate(text: text, sid: voice.sid, speed: speed)
        // sherpa-onnx does not expose word timings for these models.
        return TTSSynthesis(samples: audio.samples, words: nil)
    }

    /// Force one tiny synthesis so the first real utterance has no warmup lag.
    func warmUp() {
        guard let voice = modelVoices.first else { return }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        _ = tts.generate(text: "Hi.", sid: voice.sid, speed: 1.0)
    }
}
