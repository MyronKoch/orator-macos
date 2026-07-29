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
    /// The bundled default engine. Nullable so it can be UNLOADED to reclaim
    /// its ~380 MB for users who live entirely in Piper/Kitten. Guarded by
    /// `providerLock`. The model paths are kept so it can be reloaded.
    private var kokoro: KokoroProvider?
    private let kokoroModelPath: URL
    private let kokoroVoicesPath: URL

    /// Thread-safe read of the optional Kokoro provider.
    private func kokoroProvider() -> KokoroProvider? {
        providerLock.lock(); defer { providerLock.unlock() }
        return kokoro
    }

    /// Whether Kokoro is currently loaded (the toggle's on-state).
    var isKokoroEnabled: Bool { kokoroProvider() != nil }

    /// Load or unload Kokoro. Unloading releases the provider and returns MLX's
    /// cache to the OS (~380 MB). Safe to call from the main thread. Callers
    /// must ensure the current voice isn't a Kokoro voice before disabling.
    func setKokoroEnabled(_ enabled: Bool) {
        if enabled {
            guard kokoroProvider() == nil,
                  let loaded = try? KokoroProvider(
                      modelPath: kokoroModelPath, voicesPath: kokoroVoicesPath
                  ) else { return }
            providerLock.lock(); kokoro = loaded; providerLock.unlock()
            oratorLog("kokoro: enabled (reloaded)")
        } else {
            guard kokoroProvider() != nil else { return }
            providerLock.lock(); kokoro = nil; providerLock.unlock()
            KokoroProvider.releaseCachedMemory()
            oratorLog("kokoro: disabled (released ~380 MB)")
        }
    }
    /// Downloadable sherpa-onnx models keyed by their catalog archive name.
    /// Sherpa models are loaded LAZILY (only when a voice is actually spoken)
    /// and bounded by an LRU cap, so RAM stays ~Kokoro + the active voice no
    /// matter how many voices are installed. Availability comes from the catalog
    /// on disk, not from what happens to be loaded.
    private var loadedModels: [String: SherpaProvider] = [:]
    private var lruOrder: [String] = []          // archives, most-recently-used last
    private let maxLoadedModels = 2              // cap resident sherpa models
    private let providerLock = NSLock()

    /// VoiceInfos a catalog model declares, without loading it.
    private func catalogVoiceInfos(for model: CatalogModel) -> [VoiceInfo] {
        model.voices.map { voice in
            VoiceInfo(
                id: VoiceInfo.namespaced(provider: model.engine, local: voice.localID),
                displayName: voice.displayName,
                provider: model.engine,
                language: "en",
                supportsWordTimings: false
            )
        }
    }

    /// Return the loaded provider for `model`, loading it on demand (and evicting
    /// the least-recently-used sherpa model past the cap). Must be called off the
    /// main thread (it can block on model load). Returns nil if the load fails.
    private func loadedProvider(for model: CatalogModel) -> SherpaProvider? {
        providerLock.lock()
        if let existing = loadedModels[model.archive] {
            lruOrder.removeAll { $0 == model.archive }
            lruOrder.append(model.archive)
            providerLock.unlock()
            return existing
        }
        providerLock.unlock()

        // Load outside the lock (it is slow), then publish under the lock.
        let dir = VoiceCatalog.installDir(for: model)
        guard Self.containsModel(at: dir),
              let provider = try? SherpaProvider(
                  id: model.engine, modelDir: dir, kind: model.kind, voices: model.voices
              )
        else { return nil }

        providerLock.lock()
        loadedModels[model.archive] = provider
        lruOrder.removeAll { $0 == model.archive }
        lruOrder.append(model.archive)
        while lruOrder.count > maxLoadedModels {
            let evict = lruOrder.removeFirst()
            loadedModels[evict] = nil
        }
        providerLock.unlock()
        oratorLog("lazy-loaded \(model.archive) (\(loadedModels.count) sherpa models resident)")
        return provider
    }

    /// Resolve a namespaced catalog voice to its installed model. Unknown or
    /// unavailable voices fall back to Kokoro, the bundled default.
    /// Resolve (and lazily load) the provider that owns `voiceID`. Call only on
    /// a background/synth thread: it may block loading the model. UI validation
    /// uses `canSpeak(voiceID:)` instead, which never loads.
    private func provider(for voiceID: String) -> TTSProvider? {
        if let model = VoiceCatalog.model(forVoiceID: voiceID),
           isInstalled(model),
           let provider = loadedProvider(for: model) {
            return provider
        }
        return kokoroProvider()
    }
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

    var voiceNames: [String] { kokoroProvider()?.localVoiceNames ?? [] }

    /// Every voice across all installed providers, namespaced and in catalog
    /// order after the bundled Kokoro voices.
    var availableVoices: [VoiceInfo] {
        // From the catalog on disk, NOT from what's loaded - so an installed but
        // never-used voice still shows in the picker without costing RAM.
        let catalogVoices = VoiceCatalog.models
            .filter { isInstalled($0) }
            .flatMap { catalogVoiceInfos(for: $0) }
        return (kokoroProvider()?.voices() ?? []) + catalogVoices
    }

    /// Kitten (sherpa-onnx) voices only, or empty when that engine isn't loaded.
    /// Their ids are namespaced (`kitten:0`...); Kokoro voices stay bare names in
    /// the picker for backward-compatible saved prefs, so the UI concatenates
    /// `voiceNames` (bare Kokoro) with these.
    private var kittenModel: CatalogModel? {
        VoiceCatalog.models.first { $0.archive == "kitten-mini-en-v0_8" }
    }

    var kittenVoices: [VoiceInfo] {
        guard let kittenModel, isInstalled(kittenModel) else { return [] }
        return catalogVoiceInfos(for: kittenModel)
    }

    var isKittenAvailable: Bool {
        guard let kittenModel else { return false }
        return isInstalled(kittenModel)
    }

    /// Whether ANY installed provider can speak `voiceID` (bare Kokoro name or a
    /// namespaced id like `kitten:0`). Catalog/disk-based, so it never triggers a
    /// model load - safe to call from the UI to validate a selection.
    func canSpeak(voiceID: String) -> Bool {
        if let model = VoiceCatalog.model(forVoiceID: voiceID) {
            return isInstalled(model)
        }
        return kokoroProvider()?.canSpeak(voiceID: voiceID) ?? false
    }

    /// Compatibility alias for callers that predate the full voice catalog.
    func reloadKittenProvider() {
        reloadCatalog()
    }

    /// No-op now that voice availability is derived from what's installed on
    /// disk (see `availableVoices`/`canSpeak`) and models load lazily on first
    /// use. Kept because callers invoke it after a download completes; the newly
    /// installed voice shows up on the next `availableVoices` read.
    func reloadCatalog() {}

    func isInstalled(_ model: CatalogModel) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: VoiceCatalog.installDir(for: model).path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    var installedVoiceIDs: Set<String> {
        providerLock.lock(); defer { providerLock.unlock() }
        return Set(VoiceCatalog.models.flatMap { model in
            loadedModels[model.archive]?.voices().map(\.id) ?? []
        })
    }

    /// Application Support directory where downloadable engine models live.
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Orator/models", isDirectory: true)
    }

    /// Load every valid catalog model found on disk. A missing or broken model
    /// is skipped so the app can continue with its other providers.
    private static func containsModel(at directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.pathExtension.lowercased() == "onnx" }
    }

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
        kokoroModelPath = modelPath
        kokoroVoicesPath = voicesPath
        let loadedKokoro = try KokoroProvider(modelPath: modelPath, voicesPath: voicesPath)
        kokoro = loadedKokoro
        // Sherpa models are NOT eager-loaded; they load lazily on first use.

        format = AVAudioFormat(
            standardFormatWithSampleRate: loadedKokoro.sampleRate,
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
            kokoroProvider()?.warmUp(voiceID: currentVoice)
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
                guard let fileProvider = provider(for: voiceKey) else {
                    throw OratorError.voiceNotFound(voiceKey)
                }

                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: fileProvider.sampleRate,
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
                        let samples = try fileProvider.synthesize(
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

        guard canSpeak(voiceID: currentVoice) else {
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
        let fallback = canSpeak(voiceID: currentVoice) ? currentVoice : nil
        var items: [VoicedChunk] = []
        for segment in segments {
            let resolved = canSpeak(voiceID: segment.voiceName)
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
                guard let chunkProvider = provider(for: item.voiceID),
                      let synthesis = try? chunkProvider.synthesize(
                          text: item.text, voiceID: item.voiceID, speed: item.speed ?? defaultSpeed
                      ), !synthesis.samples.isEmpty else { continue }
                if isCancelled(gen) { return }
                // Providers may emit at their own rate (Kokoro/Kitten 24 kHz,
                // Piper 22.05 kHz). schedule() resamples to the engine format so
                // Piper doesn't play fast/high; timing uses the source rate so
                // durations stay correct.
                schedule(samples: synthesis.samples, sampleRate: chunkProvider.sampleRate, generation: gen)
                offset += emitChunkTiming(
                    synthesis.words, chunkText: item.text, chunkIndex: chunkIndex,
                    chunkCount: items.count, offset: offset,
                    sampleCount: synthesis.samples.count, sampleRate: chunkProvider.sampleRate,
                    generation: gen
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
        sampleRate: Double,
        generation gen: Int
    ) -> TimeInterval {
        // Duration is defined by the SOURCE rate the samples were generated at
        // (resampling to the engine format preserves real-time duration), so a
        // 22.05 kHz Piper chunk reports the right length for the Reader.
        let duration = Double(sampleCount) / sampleRate
        guard let callback = onChunkTiming, !isCancelled(gen) else { return duration }
        let words = words ?? []
        let timing = ChunkTiming(
            utteranceID: gen, chunkIndex: chunkIndex, chunkCount: chunkCount,
            text: chunkText, offset: offset, duration: duration, words: words
        )
        DispatchQueue.main.async { callback(timing) }
        return duration
    }

    /// Linear-rate convert mono float samples from `srcRate` to `dstRate`.
    /// A no-op when the rates already match (Kokoro/Kitten at 24 kHz). Used so a
    /// 22.05 kHz Piper chunk plays at the correct pitch through the 24 kHz node.
    private func resample(_ samples: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard srcRate != dstRate, !samples.isEmpty,
              let srcFormat = AVAudioFormat(standardFormatWithSampleRate: srcRate, channels: 1),
              let dstFormat = AVAudioFormat(standardFormatWithSampleRate: dstRate, channels: 1),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat),
              let srcBuffer = AVAudioPCMBuffer(
                  pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count)
              )
        else { return samples }

        srcBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            UnsafeMutableRawPointer(srcBuffer.floatChannelData![0]).copyMemory(
                from: UnsafeRawPointer(src.baseAddress!),
                byteCount: src.count * MemoryLayout<Float>.stride
            )
        }

        let capacity = AVAudioFrameCount(Double(samples.count) * dstRate / srcRate) + 16
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else {
            return samples
        }
        var provided = false
        let status = converter.convert(to: dstBuffer, error: nil) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        guard status == .haveData || status == .inputRanDry else { return samples }
        let count = Int(dstBuffer.frameLength)
        guard count > 0, let channel = dstBuffer.floatChannelData?[0] else { return samples }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    private func schedule(samples rawSamples: [Float], sampleRate: Double, generation gen: Int) {
        // Resample to the engine's fixed format when the provider's rate differs
        // (Piper is 22.05 kHz vs the 24 kHz player), else the buffer plays at the
        // wrong pitch/speed.
        let samples = resample(rawSamples, from: sampleRate, to: format.sampleRate)
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(
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
