import AVFoundation
import Foundation

/// Cloud speech via Cloudflare Workers AI (Deepgram Aura + MeloTTS).
///
/// Unlike the on-device providers, `synthesize` performs a BLOCKING network
/// round-trip. That is safe because the `TTSProvider` seam calls it OFF the main
/// thread, on `OratorEngine`'s serial synthesis queue, once per chunk - so the
/// guarded concurrency core is never touched, and blocking one background chunk
/// on the network just adds the inherent latency of cloud TTS.
///
/// DEV SCAFFOLDING: this build calls Cloudflare directly with a token from a
/// local, gitignored config file OUTSIDE the repo (see `CloudCredentials`). The
/// SHIPPING architecture routes through a metered Cloudflare Worker so no token
/// is ever embedded in the app - which is exactly why this build must not be
/// published until the Pro/metering work lands.
final class CloudTTSProvider: TTSProvider, @unchecked Sendable {
    let id = "cf"
    /// Every response is normalized to the engine's 24 kHz on the way out, so
    /// the downstream schedule()/resample path treats cloud audio like Kokoro.
    let sampleRate: Double = 24_000

    private let accountID: String
    private let token: String
    private let meter: CloudUsageMeter
    private let session: URLSession

    /// Returns nil when no cloud credentials are configured, so cloud voices
    /// simply don't appear rather than failing mid-utterance.
    init?(meter: CloudUsageMeter) {
        guard let creds = CloudCredentials.load() else { return nil }
        self.accountID = creds.accountID
        self.token = creds.token
        self.meter = meter
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    func voices() -> [VoiceInfo] { CloudVoiceCatalog.voiceInfos }

    func canSpeak(voiceID: String) -> Bool {
        CloudVoiceCatalog.voice(for: voiceID) != nil
    }

    func synthesize(text: String, voiceID: String, speed: Float) throws -> TTSSynthesis {
        guard let voice = CloudVoiceCatalog.voice(for: voiceID) else {
            throw CloudTTSError.unknownVoice(voiceID)
        }
        let audio = try requestAudio(for: voice, text: text)
        // Count usage BEFORE enforcement exists - this is the metering seam.
        meter.record(model: voice.model, characters: text.count)
        let samples = try Self.decodeToMono24k(audio)
        return TTSSynthesis(samples: samples, words: nil)
    }

    // MARK: - Cloudflare request (synchronous, on the synth queue)

    private func requestAudio(for voice: CloudVoice, text: String) throws -> Data {
        let path = "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/run/\(voice.model.modelID)"
        guard let url = URL(string: path) else { throw CloudTTSError.badURL(path) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: voice.requestBody(text: text))

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Error> = .failure(CloudTTSError.noData)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { outcome = .failure(error); return }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(CloudTTSError.noData); return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                outcome = .failure(CloudTTSError.http(http.statusCode, body)); return
            }
            guard let data, !data.isEmpty else {
                outcome = .failure(CloudTTSError.noData); return
            }
            // A JSON payload on a 200 is Cloudflare's error envelope, not audio.
            if data.first == UInt8(ascii: "{") {
                outcome = .failure(CloudTTSError.http(200, String(data: data, encoding: .utf8) ?? ""))
                return
            }
            outcome = .success(data)
        }
        task.resume()
        semaphore.wait()
        return try outcome.get()
    }

    // MARK: - Decode compressed audio -> mono Float @ 24 kHz

    private static func decodeToMono24k(_ data: Data) throws -> [Float] {
        // AVAudioFile needs a URL, so stage the compressed bytes in a temp file.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orator-cf-\(UUID().uuidString)")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file = try AVAudioFile(forReading: tempURL)
        let inputFormat = file.processingFormat
        let inputFrames = AVAudioFrameCount(file.length)
        guard inputFrames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrames)
        else { throw CloudTTSError.decodeFailed }
        try file.read(into: inputBuffer)

        // One AVAudioConverter pass handles BOTH the downmix to mono and the
        // resample to 24 kHz. If the file were already mono/24k this is a copy.
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw CloudTTSError.decodeFailed }

        let ratio = 24_000.0 / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputFrames) * ratio) + 4096
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity)
        else { throw CloudTTSError.decodeFailed }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }
        guard status == .haveData || status == .inputRanDry else { throw CloudTTSError.decodeFailed }

        let count = Int(outputBuffer.frameLength)
        guard count > 0, let channel = outputBuffer.floatChannelData?[0] else {
            throw CloudTTSError.decodeFailed
        }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
}

enum CloudTTSError: LocalizedError {
    case unknownVoice(String)
    case badURL(String)
    case http(Int, String)
    case noData
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .unknownVoice(let id): return "Unknown cloud voice: \(id)"
        case .badURL(let path): return "Bad Cloudflare URL: \(path)"
        case .http(let code, let body):
            let detail = body.isEmpty ? "" : " - \(body.prefix(200))"
            return "Cloudflare returned HTTP \(code)\(detail)"
        case .noData: return "Cloudflare returned no audio"
        case .decodeFailed: return "Could not decode the cloud audio response"
        }
    }
}

/// Cloudflare Workers AI credentials for the DEV build only.
///
/// Read from a local JSON file OUTSIDE the git repo:
///   ~/Library/Application Support/Orator/cloudflare.json
///   { "accountId": "...", "token": "..." }
/// Returns nil without that file, which locks all cloud voices. This whole type is throwaway
/// scaffolding: production authenticates to a metered Worker, not Cloudflare.
struct CloudCredentials {
    let accountID: String
    let token: String

    /// Read ONLY from ~/Library/Application Support/Orator/cloudflare.json, and
    /// only when it holds both an account ID and a token. Nothing is compiled in
    /// and there is no environment fallback, so a shipped build has no cloud
    /// access of its own: without the file, cloud voices show as locked Pro voices.
    static func load() -> CloudCredentials? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Orator/cloudflare.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let account = (json["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, !account.isEmpty
        else { return nil }
        return CloudCredentials(accountID: account, token: token)
    }
}

/// Counts cloud synthesis usage (characters per model), persisted locally.
///
/// This is the METERING SEAM. It only COUNTS today - it does not enforce a cap.
/// When the Pro tier + metered Worker land, enforcement plugs in here (or moves
/// server-side) with the usage history already being recorded. Thread-safe: the
/// synth queue calls `record` off the main thread.
final class CloudUsageMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private static let key = "cloudUsageCharactersByModel"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(model: CloudModel, characters: Int) {
        guard characters > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var table = defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
        table[model.rawValue, default: 0] += characters
        defaults.set(table, forKey: Self.key)
        oratorLog("cloud usage: +\(characters) chars on \(model.key) (total \(table[model.rawValue] ?? 0))")
    }

    /// Cumulative characters synthesized per model since install.
    func totals() -> [CloudModel: Int] {
        lock.lock(); defer { lock.unlock() }
        let table = defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
        var out: [CloudModel: Int] = [:]
        for model in CloudModel.allCases { out[model] = table[model.rawValue] ?? 0 }
        return out
    }

    func totalCharacters() -> Int { totals().values.reduce(0, +) }
}
