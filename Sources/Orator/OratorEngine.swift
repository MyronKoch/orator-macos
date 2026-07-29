import Foundation
import AVFoundation
import CoreAudio

private func defaultOutputDeviceChanged(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    Unmanaged<OratorEngine>.fromOpaque(clientData)
        .takeUnretainedValue()
        .refreshOutputLatency()
    return noErr
}

extension Notification.Name {
    static let oratorSpeechFinished = Notification.Name("oratorSpeechFinished")
    static let oratorSpeechStarted = Notification.Name("oratorSpeechStarted")
    static let oratorSpeechPaused = Notification.Name("oratorSpeechPaused")
    static let oratorSpeechResumed = Notification.Name("oratorSpeechResumed")
}

/// userInfo for `.oratorSpeechFinished`: distinguishes an utterance that
/// played to its natural end from one the user (or a new speak) cut off.
/// Consumers that chain follow-up playback (the reading queue) must only
/// act on `completed` - auto-starting anything after an explicit stop
/// turns "silence, please" into more talking.
enum OratorFinishReason {
    static let key = "reason"
    static let completed = "completed"
    static let stopped = "stopped"
}

enum OratorError: LocalizedError {
    case modelNotFound
    case voicesNotFound
    case voiceNotFound(String)
    case noTextToExport
    case providerNotReady(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Kokoro model not found in app bundle"
        case .voicesNotFound: return "Voice embeddings not found in app bundle"
        case .voiceNotFound(let name): return "Voice \"\(name)\" not found"
        case .noTextToExport: return "No text to export"
        case .providerNotReady(let reason): return reason
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

    /// The synthesis source. Everything below this line is engine-agnostic:
    /// the provider supplies PCM, this class still owns scheduling and the
    /// generation/lock/scheduledBuffers/synthesisDone/speaking state machine.
    private let kokoro: KokoroProvider
    private var provider: TTSProvider { kokoro }
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let latencyLock = NSLock()
    private var cachedOutputLatency: TimeInterval = 0
    private var audioConfigurationObserver: NSObjectProtocol?

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

    var voiceNames: [String] { kokoro.localVoiceNames }

    /// Every voice across all installed providers, namespaced. The picker UI
    /// can group these by `provider` once a second provider exists.
    var availableVoices: [VoiceInfo] { provider.voices() }

    var isSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return speaking
    }

    // MARK: - Reader timing surface (additive)
    //
    // Everything in this section observes playback or wraps the player node.
    // None of it participates in the playback state machine (`generation`,
    // `scheduledBuffers`, `synthesisDone`, `speaking`).

    /// Optional observer for per-chunk word timing, delivered on the main
    /// queue as each chunk of the current utterance finishes synthesis. Set
    /// it before calling `speak`. Timings for cancelled utterances are
    /// dropped, but consumers should still filter by `utteranceID`.
    var onChunkTiming: (@Sendable (ChunkTiming) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChunkTiming }
        set { lock.lock(); defer { lock.unlock() }; _onChunkTiming = newValue }
    }
    private var _onChunkTiming: (@Sendable (ChunkTiming) -> Void)?

    /// Seconds of audio played so far in the current utterance. Returns nil
    /// when the player has no live timeline - before the first play, after a
    /// stop, and (on some systems) while paused - so consumers should hold
    /// the last non-nil value they observed.
    var playbackPosition: TimeInterval? {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        return max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    /// Cached delay between rendering a sample and hearing it on the current
    /// output route. CoreAudio is queried only at startup or on route/config
    /// changes, never from the Reader's display callback.
    var outputLatency: TimeInterval {
        latencyLock.lock(); defer { latencyLock.unlock() }
        return cachedOutputLatency
    }

    /// True while the current utterance is paused. Cleared by speak/stop.
    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return _paused
    }
    private var _paused = false

    /// Pause playback without tearing down the utterance. Synthesis of later
    /// chunks continues in the background and keeps queueing on the player.
    /// No-op unless an utterance is actively speaking and not already paused.
    /// Callers are main-thread; the paused/resumed notifications post inline.
    func pause() {
        lock.lock()
        let canPause = speaking && !_paused
        if canPause { _paused = true }
        lock.unlock()
        guard canPause else { return }
        player.pause()
        NotificationCenter.default.post(name: .oratorSpeechPaused, object: nil)
    }

    /// Resume playback after `pause()`. No-op unless currently paused.
    func resume() {
        lock.lock()
        let canResume = _paused
        if canResume { _paused = false }
        lock.unlock()
        guard canResume else { return }
        player.play()
        NotificationCenter.default.post(name: .oratorSpeechResumed, object: nil)
    }

    // MARK: - Init

    init(modelPath: URL, voicesPath: URL) throws {
        kokoro = try KokoroProvider(modelPath: modelPath, voicesPath: voicesPath)

        format = AVAudioFormat(
            standardFormatWithSampleRate: kokoro.sampleRate,
            channels: 1
        )!
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
        installOutputLatencyObservers()
        refreshOutputLatency()
    }

    deinit {
        if let audioConfigurationObserver {
            NotificationCenter.default.removeObserver(audioConfigurationObserver)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultOutputDeviceChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func installOutputLatencyObservers() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultOutputDeviceChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )

        audioConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            self?.refreshOutputLatency()
        }
    }

    fileprivate func refreshOutputLatency() {
        let coreAudioLatency = Self.coreAudioOutputLatency()
        // CoreAudio's device latency is the same underlying value exposed by
        // the AVAudioEngine nodes, so combining them would count it twice.
        // Keep the output-node value only as a fallback when CoreAudio cannot
        // provide a hardware subtotal.
        let measuredLatency = coreAudioLatency > 0
            ? coreAudioLatency
            : audioEngine.outputNode.presentationLatency
        latencyLock.lock()
        cachedOutputLatency = max(0, measuredLatency)
        latencyLock.unlock()
    }

    private static func coreAudioOutputLatency() -> TimeInterval {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return 0
        }

        var sampleRate = Float64(0)
        var sampleRateSize = UInt32(MemoryLayout<Float64>.size)
        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &sampleRateAddress,
            0,
            nil,
            &sampleRateSize,
            &sampleRate
        ) == noErr, sampleRate > 0 else {
            return 0
        }

        func frameCount(_ selector: AudioObjectPropertySelector) -> UInt32 {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, &value
            ) == noErr else { return 0 }
            return value
        }

        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        var streamLatency: UInt32 = 0
        if AudioObjectGetPropertyDataSize(
            deviceID, &streamsAddress, 0, nil, &streamsSize
        ) == noErr, streamsSize > 0 {
            let count = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
            var streams = [AudioStreamID](repeating: 0, count: count)
            let streamsStatus = streams.withUnsafeMutableBytes { bytes in
                AudioObjectGetPropertyData(
                    deviceID, &streamsAddress, 0, nil, &streamsSize, bytes.baseAddress!
                )
            }
            if streamsStatus == noErr {
                for stream in streams {
                    var latency: UInt32 = 0
                    var latencySize = UInt32(MemoryLayout<UInt32>.size)
                    var latencyAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioStreamPropertyLatency,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    if AudioObjectGetPropertyData(
                        stream, &latencyAddress, 0, nil, &latencySize, &latency
                    ) == noErr {
                        streamLatency = max(streamLatency, latency)
                    }
                }
            }
        }

        let frames = frameCount(kAudioDevicePropertyLatency)
            + frameCount(kAudioDevicePropertySafetyOffset)
            + streamLatency
        return TimeInterval(frames) / sampleRate
    }

    /// Force one tiny synthesis so the first real utterance has no warmup lag.
    func warmUp() {
        synthQueue.async { [self] in
            kokoro.warmUp(voiceID: currentVoice)
        }
    }

    // MARK: - Export (offline synthesis to file)

    /// Synthesize the full text to an audio file (AAC `.m4a`) offline.
    ///
    /// This is **additive and isolated** from the live playback path: it runs on
    /// the shared `synthQueue` so it never invokes MLX concurrently with `speak`,
    /// but it touches none of the playback state machine (`generation`, `lock`,
    /// `scheduledBuffers`, `synthesisDone`, `speaking`, `player`, `audioEngine`).
    /// Progress and completion are delivered on the main queue.
    func synthesizeToFile(
        _ text: String,
        voiceName: String? = nil,
        speed: Float? = nil,
        to url: URL,
        progress: (@Sendable (Double) -> Void)? = nil,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        let chunks = TextChunker.chunk(text)
        let voiceKey = voiceName ?? currentVoice
        let spd = speed ?? self.speed

        synthQueue.async { [self] in
            func finish(_ result: Result<URL, Error>) {
                DispatchQueue.main.async { completion(result) }
            }
            do {
                guard !chunks.isEmpty else { throw OratorError.noTextToExport }
                guard provider.canSpeak(voiceID: voiceKey) else {
                    throw OratorError.voiceNotFound(voiceKey)
                }

                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: provider.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                // Write + finalize inside a nested scope so the AVAudioFile is
                // fully released (m4a container finalized and flushed to disk)
                // BEFORE we report success. Otherwise a reader that opens the
                // file immediately on completion sees an unfinalized container
                // and fails with kAudioFileUnsupportedDataFormatError.
                do {
                    let file = try AVAudioFile(forWriting: url, settings: settings)
                    let writeFormat = file.processingFormat

                    let total = chunks.count
                    for (index, chunk) in chunks.enumerated() {
                        let samples = try provider.synthesize(
                            text: chunk, voiceID: voiceKey, speed: spd
                        ).samples
                        if !samples.isEmpty,
                           let buffer = AVAudioPCMBuffer(
                               pcmFormat: writeFormat,
                               frameCapacity: AVAudioFrameCount(samples.count)
                           ) {
                            buffer.frameLength = buffer.frameCapacity
                            samples.withUnsafeBufferPointer { src in
                                UnsafeMutableRawPointer(buffer.floatChannelData![0]).copyMemory(
                                    from: UnsafeRawPointer(src.baseAddress!),
                                    byteCount: src.count * MemoryLayout<Float>.stride
                                )
                            }
                            try file.write(from: buffer)
                        }
                        let fraction = Double(index + 1) / Double(total)
                        if let progress { DispatchQueue.main.async { progress(fraction) } }
                    }
                }
                finish(.success(url))
            } catch {
                finish(.failure(error))
            }
        }
    }

    // MARK: - Speak / Stop

    func speak(_ text: String) throws {
        try speak(chunks: TextChunker.chunk(text))
    }

    /// One synthesis unit: text plus the voice to render it in. The voice is a
    /// provider-neutral id, not a Kokoro embedding - resolving it is the
    /// provider's job, which is what lets a second engine slot in here.
    private struct VoicedChunk {
        let text: String
        let voiceID: String
        /// Per-chunk rate override; nil falls back to the engine's speed.
        let speed: Float?
    }

    /// Speak pre-chunked text in the current voice. The Reader window chunks its
    /// document once and restarts mid-list for click-to-jump, so chunk
    /// boundaries stay stable across seeks. Returns the utterance ID that tags
    /// this utterance's `ChunkTiming` callbacks, or -1 if nothing to say.
    @discardableResult
    func speak(chunks: [String]) throws -> Int {
        guard !chunks.isEmpty else { return -1 }

        guard provider.canSpeak(voiceID: currentVoice) else {
            oratorLog("speak: lookup failed for \(currentVoice); available: \(Array(voiceNames.prefix(4)))")
            throw OratorError.voiceNotFound(currentVoice)
        }
        let items = chunks.map { VoicedChunk(text: $0, voiceID: currentVoice, speed: nil) }
        return try play(items)
    }

    /// Speak a cast list: each segment carries its own voice. The segment text
    /// is chunked internally (keeping the segment's voice) so long narration
    /// still starts fast. A segment whose voice can't be resolved falls back to
    /// the current voice rather than aborting the whole passage. Returns the
    /// utterance ID, or -1 if there was nothing to say.
    @discardableResult
    func speak(segments: [SpeechSegment]) throws -> Int {
        let fallback = provider.canSpeak(voiceID: currentVoice) ? currentVoice : nil
        var items: [VoicedChunk] = []
        for segment in segments {
            let resolved = provider.canSpeak(voiceID: segment.voiceName)
                ? segment.voiceName
                : fallback
            guard let voiceID = resolved else { continue }
            for chunk in TextChunker.chunk(segment.text) {
                items.append(VoicedChunk(text: chunk, voiceID: voiceID, speed: segment.speed))
            }
        }
        guard !items.isEmpty else { return -1 }
        return try play(items)
    }

    /// The guarded playback core. ALL speech routes through here so the
    /// generation/lock/scheduledBuffers/synthesisDone/speaking state machine
    /// lives in exactly one place, whatever the voice mix.
    private func play(_ items: [VoicedChunk]) throws -> Int {
        // Cancel anything in flight and reset playback state.
        lock.lock()
        generation += 1
        let gen = generation
        scheduledBuffers = 0
        synthesisDone = false
        speaking = true
        _paused = false
        lock.unlock()

        player.stop()
        if !audioEngine.isRunning {
            try audioEngine.start()
            refreshOutputLatency()
        }
        player.play()
        NotificationCenter.default.post(name: .oratorSpeechStarted, object: nil)

        let defaultSpeed = self.speed
        synthQueue.async { [self] in
            var offset: TimeInterval = 0
            for (chunkIndex, item) in items.enumerated() {
                if isCancelled(gen) { return }
                guard let synthesis = try? provider.synthesize(
                    text: item.text, voiceID: item.voiceID, speed: item.speed ?? defaultSpeed
                ), !synthesis.samples.isEmpty else { continue }
                if isCancelled(gen) { return }
                schedule(samples: synthesis.samples, generation: gen)
                offset += emitChunkTiming(
                    synthesis.words, chunkText: item.text, chunkIndex: chunkIndex,
                    chunkCount: items.count, offset: offset,
                    sampleCount: synthesis.samples.count, generation: gen
                )
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
        return gen
    }

    func stop() {
        lock.lock()
        generation += 1
        synthesisDone = true
        scheduledBuffers = 0
        let wasSpeaking = speaking
        speaking = false
        _paused = false
        lock.unlock()

        player.stop()
        if wasSpeaking { postFinished(reason: OratorFinishReason.stopped) }
    }

    // MARK: - Internals

    private func isCancelled(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation != gen
    }

    /// Build and deliver a `ChunkTiming` on the main queue. Returns the
    /// chunk's audio duration so the synthesis loop can advance its running
    /// utterance offset whether or not anyone is listening.
    private func emitChunkTiming(
        _ words: [WordTiming]?,
        chunkText: String,
        chunkIndex: Int,
        chunkCount: Int,
        offset: TimeInterval,
        sampleCount: Int,
        generation gen: Int
    ) -> TimeInterval {
        let duration = Double(sampleCount) / provider.sampleRate
        guard let callback = onChunkTiming, !isCancelled(gen) else { return duration }
        let words = words ?? []
        let timing = ChunkTiming(
            utteranceID: gen, chunkIndex: chunkIndex, chunkCount: chunkCount,
            text: chunkText, offset: offset, duration: duration, words: words
        )
        DispatchQueue.main.async { callback(timing) }
        return duration
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

    private func postFinished(reason: String = OratorFinishReason.completed) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .oratorSpeechFinished, object: nil,
                userInfo: [OratorFinishReason.key: reason]
            )
        }
    }
}
