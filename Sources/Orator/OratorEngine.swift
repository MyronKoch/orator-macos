import Foundation
import AVFoundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

extension Notification.Name {
    static let oratorSpeechFinished = Notification.Name("oratorSpeechFinished")
    static let oratorSpeechStarted = Notification.Name("oratorSpeechStarted")
}

enum OratorError: LocalizedError {
    case modelNotFound
    case voicesNotFound
    case voiceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Kokoro model not found in app bundle"
        case .voicesNotFound: return "Voice embeddings not found in app bundle"
        case .voiceNotFound(let name): return "Voice \"\(name)\" not found"
        }
    }
}

/// In-process Kokoro TTS with pipelined chunk synthesis.
///
/// Long selections are split into sentence chunks. The first chunk starts
/// playing as soon as it is synthesized while later chunks are generated in
/// the background and appended to the AVAudioPlayerNode queue - so a full
/// article starts speaking in under a second instead of after the whole
/// synthesis pass.
final class OratorEngine: @unchecked Sendable {

    private let tts: KokoroTTS
    private let voices: [String: MLXArray]
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    /// All MLX inference is serialized on this queue.
    private let synthQueue = DispatchQueue(label: "app.orator.synth", qos: .userInitiated)

    private let lock = NSLock()
    private var generation = 0          // bumping this cancels in-flight work
    private var scheduledBuffers = 0    // buffers queued on the player
    private var synthesisDone = true    // no more chunks coming for current utterance
    private var speaking = false

    // MARK: - Settings (persisted by the app layer)

    var currentVoice: String = "af_heart"
    var speed: Float = 1.0

    var voiceNames: [String] {
        voices.keys.map { $0.replacingOccurrences(of: ".npy", with: "") }.sorted()
    }

    var isSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return speaking
    }

    // MARK: - Init

    init(modelPath: URL, voicesPath: URL) throws {
        GPU.set(cacheLimit: 50 * 1024 * 1024)
        GPU.set(memoryLimit: 900 * 1024 * 1024)

        tts = KokoroTTS(modelPath: modelPath)

        guard let loaded = NpyzReader.read(fileFromPath: voicesPath) else {
            throw OratorError.voicesNotFound
        }
        voices = loaded

        format = AVAudioFormat(
            standardFormatWithSampleRate: Double(KokoroTTS.Constants.samplingRate),
            channels: 1
        )!
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
    }

    /// Force one tiny synthesis so the first real utterance has no warmup lag.
    func warmUp() {
        synthQueue.async { [self] in
            guard let voice = voices[currentVoice + ".npy"] ?? voices.values.first.map({ $0 }) else { return }
            _ = try? tts.generateAudio(voice: voice, language: .enUS, text: "Hi.", speed: 1.0)
        }
    }

    // MARK: - Speak / Stop

    func speak(_ text: String) throws {
        let chunks = TextChunker.chunk(text)
        guard !chunks.isEmpty else { return }

        guard let voiceEmbedding = voices[currentVoice + ".npy"] else {
            throw OratorError.voiceNotFound(currentVoice)
        }
        let language: Language = currentVoice.hasPrefix("b") ? .enGB : .enUS
        let speed = self.speed

        // Cancel anything in flight and reset playback state.
        lock.lock()
        generation += 1
        let gen = generation
        scheduledBuffers = 0
        synthesisDone = false
        speaking = true
        lock.unlock()

        player.stop()
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        player.play()
        NotificationCenter.default.post(name: .oratorSpeechStarted, object: nil)

        synthQueue.async { [self] in
            for chunk in chunks {
                if isCancelled(gen) { return }
                guard let (samples, _) = try? tts.generateAudio(
                    voice: voiceEmbedding, language: language, text: chunk, speed: speed
                ), !samples.isEmpty else { continue }
                if isCancelled(gen) { return }
                schedule(samples: samples, generation: gen)
            }
            lock.lock()
            if generation == gen {
                synthesisDone = true
                let idle = scheduledBuffers == 0
                if idle { speaking = false }
                lock.unlock()
                if idle { postFinished() }
            } else {
                lock.unlock()
            }
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        synthesisDone = true
        scheduledBuffers = 0
        let wasSpeaking = speaking
        speaking = false
        lock.unlock()

        player.stop()
        if wasSpeaking { postFinished() }
    }

    // MARK: - Internals

    private func isCancelled(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation != gen
    }

    private func schedule(samples: [Float], generation gen: Int) {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { src in
            UnsafeMutableRawPointer(buffer.floatChannelData![0]).copyMemory(
                from: UnsafeRawPointer(src.baseAddress!),
                byteCount: src.count * MemoryLayout<Float>.stride
            )
        }

        lock.lock()
        guard generation == gen else { lock.unlock(); return }
        scheduledBuffers += 1
        lock.unlock()

        player.scheduleBuffer(buffer) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard self.generation == gen else { self.lock.unlock(); return }
            self.scheduledBuffers -= 1
            let finished = self.scheduledBuffers == 0 && self.synthesisDone
            if finished { self.speaking = false }
            self.lock.unlock()
            if finished { self.postFinished() }
        }
    }

    private func postFinished() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .oratorSpeechFinished, object: nil)
        }
    }
}
