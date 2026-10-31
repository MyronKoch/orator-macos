import Foundation
import NaturalLanguage
import PhononTTS

/// Phonon 31M (Gradium, Apache-2.0) behind the `TTSProvider` seam - Orator's
/// default engine.
///
/// The Core ML bundle ships in the app as `Resources/PhononModels`. Phonon keeps
/// compiled models beside the packages, so the bundle is first copied to a
/// writable folder (Application Support/PhononTTS/models) and compiled for this
/// Mac there; both happen once, in the background, starting at init. Until that
/// finishes the voices are still listed (read from the bundle's voice files), and
/// a `synthesize` call simply waits for the load.
///
/// Phonon normalises text itself (numbers, money, times, URLs) when loaded as
/// English. It has no speed control (see `TimeStretch`) and reports no word timings.
final class PhononProvider: TTSProvider, @unchecked Sendable {
    let id = "phonon"
    let sampleRate: Double = Phonon.sampleRate

    /// Kokoro voice -> its closest Phonon voice. The same table Phonon's own
    /// OpenAI server uses for `--voice-alias`, so a saved Kokoro preference maps
    /// onto the voice Myron already heard. The Kokoro prefix (af, am, bf, bm)
    /// also supplies each Phonon voice's accent and gender label.
    static let kokoroEquivalent: [String: String] = [
        "af_alloy": "Bryony", "af_aoede": "Elodie-Rose", "af_bella": "Hadley",
        "af_heart": "Harper", "af_jessica": "Imogen", "af_kore": "Lottie",
        "af_nova": "Zoey", "af_river": "Everly", "af_sarah": "Delia", "af_sky": "Juniper",
        "am_adam": "Miles", "am_echo": "Easton", "am_eric": "Preston", "am_fenrir": "Russell",
        "am_liam": "Micah", "am_michael": "Trevor", "am_onyx": "Edwin", "am_puck": "Teddy",
        "am_santa": "Spencer",
        "bf_alice": "Fairy Godmother", "bf_emma": "Maeve", "bf_isabella": "Pippa",
        "bf_lily": "Freya",
        "bm_daniel": "Alfie", "bm_fable": "Master Aldric", "bm_george": "Hugh", "bm_lewis": "Toby",
    ]

    /// Voices that are characters rather than narrators, listed in their own
    /// picker section even when they stand in for a Kokoro voice.
    static let characterVoices: Set<String> = [
        "Azgorath", "Captain Silas Blackwater", "Fairy Godmother", "Fennick the Young Elf",
        "Grub the Ogre", "Master Aldric", "Morwenna of the Deep", "Old Mortlake",
        "Sir Bramwell", "The Snow Queen", "The Thing Under the Stairs", "Vyrmathrax the Ancient",
    ]

    static let defaultVoice = "Harper"

    /// The namespaced Phonon id for a bare Kokoro voice name, if it has one.
    static func voiceID(forKokoro name: String) -> String? {
        kokoroEquivalent[name].map { VoiceInfo.namespaced(provider: "phonon", local: $0) }
    }

    private let voiceNames: [String]
    private let labels: [String: String]

    private let loadGroup = DispatchGroup()
    private var loadResult: Result<Phonon, Error>?
    /// Serializes voice switches with synthesis: Phonon holds ONE current voice.
    private let synthLock = NSLock()

    /// The bundled model, or (for a dev binary run outside an app bundle) one
    /// already installed in Application Support. Nil when neither exists, which
    /// leaves Kokoro as the default.
    static func makeIfAvailable() -> PhononProvider? {
        if let bundled = Bundle.main.url(forResource: "PhononModels", withExtension: nil) {
            return PhononProvider(source: bundled, install: true)
        }
        if PhononModels.isInstalled() {
            return PhononProvider(source: PhononModels.defaultDirectory, install: false)
        }
        return nil
    }

    private init?(source: URL, install: Bool) {
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: source.appendingPathComponent("voices").path
        )) ?? []
        let names = files
            .filter { $0.hasSuffix(".safetensors") }
            .map { String($0.dropLast(".safetensors".count)) }
            .filter { $0 != "default" }
        guard !names.isEmpty else { return nil }

        var labels: [String: String] = [:]
        for (kokoro, phonon) in Self.kokoroEquivalent where !Self.characterVoices.contains(phonon) {
            let accent = kokoro.hasPrefix("a") ? "US" : "UK"
            let gender = kokoro.dropFirst().hasPrefix("f") ? "Female" : "Male"
            labels[phonon] = "\(accent) \(gender)"
        }
        self.labels = labels
        // Narrators grouped US F, US M, UK F, UK M (Kokoro's order), then characters.
        let rank = { (name: String) -> String in
            if let kokoro = Self.kokoroEquivalent.first(where: { $0.value == name })?.key,
               !Self.characterVoices.contains(name) {
                return "0\(kokoro.prefix(2))\(name)"
            }
            return Self.characterVoices.contains(name) ? "2\(name)" : "1\(name)"
        }
        voiceNames = names.sorted { rank($0) < rank($1) }

        loadGroup.enter()
        Task.detached(priority: .userInitiated) { [self] in
            let started = Date()
            do {
                let dir = install ? try PhononModels.install(bundled: source) : source
                let compiling = Phonon.needsCompiling(dir)
                let tts = try await Phonon.load(models: dir, language: .english)
                try await tts.setVoice(Self.defaultVoice)
                loadResult = .success(tts)
                oratorLog(String(format: "phonon: loaded %d voices in %.1fs%@",
                                 tts.voices.count, Date().timeIntervalSince(started),
                                 compiling ? " (first-run compile)" : ""))
            } catch {
                loadResult = .failure(error)
                oratorLog("phonon: load FAILED: \(error)")
            }
            loadGroup.leave()
        }
    }

    func voices() -> [VoiceInfo] {
        voiceNames.map { name in
            VoiceInfo(
                id: VoiceInfo.namespaced(provider: id, local: name),
                displayName: labels[name].map { "\(name)  (\($0))" } ?? name,
                provider: id,
                language: "en",
                supportsWordTimings: false
            )
        }
    }

    /// Narrator voices only (no characters), for the picker's first section.
    func isCharacter(_ voiceID: String) -> Bool {
        Self.characterVoices.contains(VoiceInfo.localID(of: voiceID))
    }

    func canSpeak(voiceID: String) -> Bool {
        guard VoiceInfo.providerID(of: voiceID) == id else { return false }
        return voiceNames.contains(VoiceInfo.localID(of: voiceID))
    }

    func synthesize(text: String, voiceID: String, speed: Float) throws -> TTSSynthesis {
        let name = VoiceInfo.localID(of: voiceID)
        guard voiceNames.contains(name) else { throw OratorError.voiceNotFound(name) }

        loadGroup.wait()
        guard let loadResult else { throw OratorError.providerNotReady("Phonon did not load") }
        let tts = try loadResult.get()

        synthLock.lock()
        defer { synthLock.unlock() }
        if tts.voice != name {
            try Self.blocking { try await tts.setVoice(name) }
        }
        // Sentence by sentence, so each pause can fit its sentence instead of
        // Phonon's one fixed half-second gap (Myron preferred this by ear,
        // 2026-10-31). Phonon restarts per sentence internally anyway, so the
        // speech itself is unchanged.
        var samples: [Float] = []
        for sentence in Self.sentences(in: text) {
            var part = try Self.blocking { try await tts.synthesize(sentence) }
            Self.fadeInRestarts(&part)
            samples += Self.trimmingSilence(part)
            samples += [Float](repeating: 0, count: Int(Self.pause(after: sentence) * sampleRate))
        }
        // Phonon has no speed control, so speed is applied afterwards as a
        // pitch-preserving tempo change.
        return TTSSynthesis(samples: TimeStretch.apply(samples, rate: speed, sampleRate: sampleRate), words: nil)
    }

    /// Phonon restarts its decoder for each sentence, and every restart opens
    /// with the same transient: ~-40 dBFS in the first millisecond, gone by ~5 ms,
    /// out of near-silence - an audible pop before each sentence (measured
    /// 2026-10-22 from in-app chunk dumps). Restarts always land on Phonon's
    /// 80 ms output frame grid after a pause, so a 10 ms raised-cosine fade-in at
    /// every grid point that follows 40 ms of quiet removes them without touching
    /// speech, which starts later than that.
    static let frameLength = 1920   // 80 ms at 24 kHz, Phonon's chunk size
    static let fadeInFrames = 240   // 10 ms
    static let quietLookback = 960  // 40 ms
    static let quietLevel: Float = 0.003

    static func fadeInRestarts(_ samples: inout [Float]) {
        var start = 0
        while start < samples.count {
            let afterPause = start == 0 || !samples[max(0, start - quietLookback)..<start]
                .contains { abs($0) >= quietLevel }
            if afterPause {
                for index in 0..<min(fadeInFrames, samples.count - start) {
                    samples[start + index] *= 0.5 - 0.5 * cos(Float.pi * Float(index) / Float(fadeInFrames))
                }
            }
            start += frameLength
        }
    }

    // MARK: - Natural pauses

    /// Sentences as Apple's tokenizer sees them, which (unlike a split on every
    /// period) keeps "Mr. Smith" and "e.g." inside their sentence.
    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }

    /// The pause after a sentence, in seconds: quick after a short beat ("Dad
    /// put it on."), a held beat after a short setup question ("And
    /// honestly?"), with up to 12% jitter so no two gaps match - identical gaps
    /// are what made the old pacing sound like a metronome.
    static func pause(after sentence: String) -> Double {
        let words = sentence.split(whereSeparator: \.isWhitespace).count
        let trimmed = sentence.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "?!.")))
        let base: Double
        if trimmed.hasSuffix("?") { base = words <= 3 ? 0.52 : 0.38 }
        else if words <= 4 { base = 0.21 }
        else if sentence.hasSuffix("\"") || sentence.hasSuffix("\u{201D}") { base = 0.33 }
        else { base = 0.30 }
        return base * Double.random(in: 0.88...1.12)
    }

    /// Drop the dead air Phonon leaves around a sentence, keeping a 30 ms
    /// lead-in and 50 ms tail so onsets and endings are never clipped.
    static func trimmingSilence(_ samples: [Float]) -> [Float] {
        let level: Float = 0.004
        guard let first = samples.firstIndex(where: { abs($0) > level }),
              let last = samples.lastIndex(where: { abs($0) > level }) else { return samples }
        return Array(samples[max(0, first - 720)..<min(samples.count, last + 1200)])
    }

    /// Run Phonon's async API to completion from the (synchronous) synth queue.
    /// Safe from deadlock: Phonon does its work on its own private queue, never
    /// on the thread that waits here.
    private static func blocking<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.result = .success(try await work()) }
            catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

/// Carries an async result back to the thread blocked in `PhononProvider.blocking`;
/// the semaphore orders the write before the read.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
