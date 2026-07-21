import CryptoKit
import Foundation

struct ScriptCast: Codable, Sendable, Equatable {
    var characterVoices: [String: String]
    var narratorVoice: String
}

/// Local per-script casts, addressed by the SHA-256 of the script contents.
final class ScriptCastStore: @unchecked Sendable {
    private static let defaultsKey = "scriptCasts"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var storedCasts: [String: ScriptCast]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: ScriptCast].self, from: saved) {
            storedCasts = decoded
        } else {
            storedCasts = [:]
        }
    }

    static func contentHash(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func cast(forContentHash contentHash: String) -> ScriptCast? {
        lock.lock()
        defer { lock.unlock() }
        return storedCasts[contentHash]
    }

    func set(contentHash: String, cast: ScriptCast) {
        lock.lock()
        storedCasts[contentHash] = cast
        persistLocked()
        lock.unlock()
    }

    func remove(contentHash: String) {
        lock.lock()
        if storedCasts.removeValue(forKey: contentHash) != nil { persistLocked() }
        lock.unlock()
    }

    var all: [(contentHash: String, cast: ScriptCast)] {
        lock.lock()
        defer { lock.unlock() }
        return storedCasts.map { (contentHash: $0.key, cast: $0.value) }
            .sorted { $0.contentHash < $1.contentHash }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(storedCasts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
