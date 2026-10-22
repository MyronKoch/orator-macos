import Foundation

/// Speech from OpenAI-compatible TTS servers running on THIS Mac (Phonon,
/// Pocket TTS, or anything else that speaks `POST /v1/audio/speech`).
///
/// This is how a user brings their own local engines - including a cloned voice
/// that must never ship inside Orator - without Orator bundling them. It is NOT
/// the cloud path: every server URL is required to be loopback (127.0.0.1, ::1,
/// localhost), so text never leaves the machine and the on-device promise holds.
///
/// Like CloudTTSProvider, `synthesize` blocks on a network round-trip, which is
/// safe because the seam calls it on the serial synthesis queue, off main.
final class LocalTTSProvider: TTSProvider, @unchecked Sendable {
    let id = "local"
    /// Requested as raw 16-bit mono PCM. Both Phonon and Pocket emit 24 kHz,
    /// which matches the engine, so no resampling happens downstream. PCM (not
    /// wav) because a streamed wav carries no length in its header.
    let sampleRate: Double = 24_000

    struct Server: Sendable {
        let id: String       // namespace segment: "phonon", "pocket"
        let name: String     // picker group label
        let baseURL: URL
        let voices: [String]
    }

    /// Mutable because a voice cloned while the app runs must appear without a
    /// relaunch. Read on the synth queue, written from main via refresh(), so it
    /// sits behind a lock.
    private var storedServers: [Server]
    private let serversLock = NSLock()
    var servers: [Server] {
        serversLock.lock(); defer { serversLock.unlock() }
        return storedServers
    }
    private let session: URLSession

    /// Returns nil when no configured server is reachable, so the picker simply
    /// shows no local section instead of voices that fail on use.
    init?() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)

        let reachable = Self.discover()
        guard !reachable.isEmpty else { return nil }
        storedServers = reachable
        oratorLog("local TTS: \(reachable.map { "\($0.name) (\($0.voices.count))" }.joined(separator: ", "))")
    }

    private static func discover() -> [Server] {
        LocalTTSConfig.load().compactMap { entry -> Server? in
            guard isLoopback(entry.url),
                  let voices = fetchVoices(entry.url), !voices.isEmpty
            else { return nil }
            return Server(id: entry.id, name: entry.name, baseURL: entry.url, voices: voices)
        }
    }

    /// Re-read every server's voice list, e.g. after cloning a new voice. Keeps
    /// the previous list if nothing answers, so a momentary outage does not
    /// wipe the picker.
    func refresh() {
        let fresh = Self.discover()
        guard !fresh.isEmpty else { return }
        serversLock.lock(); storedServers = fresh; serversLock.unlock()
    }

    /// Base URL of a server by id ("pocket"), for clone/delete calls.
    func baseURL(forServer id: String) -> URL? {
        servers.first { $0.id == id }?.baseURL
    }

    func voices() -> [VoiceInfo] {
        servers.flatMap { server in
            server.voices.map { voice in
                VoiceInfo(
                    id: VoiceInfo.namespaced(provider: id, local: "\(server.id):\(voice)"),
                    displayName: voice.replacingOccurrences(of: "_", with: " ").capitalized,
                    provider: id,
                    language: "en",
                    supportsWordTimings: false
                )
            }
        }
    }

    func canSpeak(voiceID: String) -> Bool { resolve(voiceID) != nil }

    func synthesize(text: String, voiceID: String, speed: Float) throws -> TTSSynthesis {
        guard let (server, voice) = resolve(voiceID) else {
            throw LocalTTSError.unknownVoice(voiceID)
        }
        let pcm = try requestPCM(server: server, voice: voice, text: text, speed: speed)
        return TTSSynthesis(samples: Self.int16ToFloat(pcm), words: nil)
    }

    /// `local:<server>:<voice>` -> the server and the voice name. Voice names can
    /// contain spaces ("Fairy Godmother"), so split only on the FIRST colon.
    private func resolve(_ voiceID: String) -> (Server, String)? {
        guard VoiceInfo.providerID(of: voiceID) == id else { return nil }
        let local = VoiceInfo.localID(of: voiceID)
        guard let colon = local.firstIndex(of: ":") else { return nil }
        let serverID = String(local[..<colon])
        let voice = String(local[local.index(after: colon)...])
        guard let server = servers.first(where: { $0.id == serverID }),
              server.voices.contains(voice) else { return nil }
        return (server, voice)
    }

    // MARK: - HTTP

    private func requestPCM(server: Server, voice: String, text: String, speed: Float) throws -> Data {
        var request = URLRequest(url: server.baseURL.appendingPathComponent("v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "tts-1",
            "input": text,
            "voice": voice,
            "response_format": "pcm",
            // Phonon currently ignores per-request speed (it has one server-wide
            // pacing setting); sent anyway so servers that honour it can.
            "speed": speed,
        ])

        // Both servers cap at two concurrent requests and answer 429 beyond
        // that (e.g. when another app is also speaking), so back off and retry
        // rather than dropping the chunk.
        var lastError: Error = LocalTTSError.noAudio
        for attempt in 0..<4 {
            switch Self.send(request, session: session) {
            case .success(let data):
                return data
            case .failure(let error):
                lastError = error
                if case LocalTTSError.http(429, _) = error {
                    Thread.sleep(forTimeInterval: 0.25 * Double(attempt + 1))
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    private static func send(_ request: URLRequest, session: URLSession) -> Result<Data, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Error> = .failure(LocalTTSError.noAudio)
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { outcome = .failure(error); return }
            guard let http = response as? HTTPURLResponse else { return }
            guard (200..<300).contains(http.statusCode) else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                outcome = .failure(LocalTTSError.http(http.statusCode, body)); return
            }
            guard let data, data.count >= 2 else { return }
            outcome = .success(data)
        }.resume()
        semaphore.wait()
        return outcome
    }

    /// GET /v1/audio/voices. Phonon returns {"voices": [...], "aliases": {...}},
    /// Pocket {"voices": [...], "default": "..."}; only the voice list matters.
    /// Short timeout: this runs at engine startup and a dead server must not
    /// stall launch.
    private static func fetchVoices(_ base: URL) -> [String]? {
        var request = URLRequest(url: base.appendingPathComponent("v1/audio/voices"))
        request.timeoutInterval = 1.5
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        guard case .success(let data) = send(request, session: URLSession(configuration: config)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = json["voices"] as? [String]
        else { return nil }
        return voices
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "localhost"
    }

    /// Little-endian Int16 -> Float in -1...1.
    private static func int16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                samples[index] = Float(value) / 32_768
            }
        }
        return samples
    }
}

enum LocalTTSError: LocalizedError {
    case unknownVoice(String)
    case http(Int, String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .unknownVoice(let id): return "Unknown local voice: \(id)"
        case .http(let code, let body):
            return "Local TTS server returned HTTP \(code)\(body.isEmpty ? "" : " - \(body.prefix(200))")"
        case .noAudio: return "The local TTS server returned no audio"
        }
    }
}

/// Which local servers to look for.
///
/// Read from ~/Library/Application Support/Orator/local-tts.json:
///   { "servers": [ { "id": "phonon", "name": "Phonon", "url": "http://127.0.0.1:8881" } ] }
/// With no file, probe the two well-known defaults - harmless on any Mac where
/// nothing listens there, because unreachable servers are simply skipped.
struct LocalTTSConfig {
    let id: String
    let name: String
    let url: URL

    private static let defaults = [
        LocalTTSConfig(id: "phonon", name: "Phonon", url: URL(string: "http://127.0.0.1:8881")!),
        LocalTTSConfig(id: "pocket", name: "Pocket", url: URL(string: "http://127.0.0.1:8882")!),
    ]

    static func load() -> [LocalTTSConfig] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let file = base.appendingPathComponent("Orator/local-tts.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["servers"] as? [[String: Any]]
        else { return defaults }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty, !id.contains(":"),
                  let urlString = entry["url"] as? String, let url = URL(string: urlString)
            else { return nil }
            return LocalTTSConfig(id: id, name: entry["name"] as? String ?? id.capitalized, url: url)
        }
    }
}
