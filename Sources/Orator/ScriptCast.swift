import CryptoKit
import Foundation

struct ScriptCast: Codable, Sendable, Equatable {
    /// Speeds are multipliers on the engine's rate. The bounds are wider than
    /// the global speed picker because a table read uses pace as characterisation.
    static let minSpeed: Float = 0.5
    static let maxSpeed: Float = 2.0
    static let defaultSpeed: Float = 1.0

    var characterVoices: [String: String]
    var narratorVoice: String
    /// Per-character rate. Missing entries speak at `defaultSpeed`.
    var characterSpeeds: [String: Float] = [:]
    var narratorSpeed: Float = defaultSpeed
    /// Applied on top of every per-character speed, so the whole read can be
    /// sped up or slowed without re-tuning each character.
    var overallSpeed: Float = defaultSpeed

    static func clamp(_ speed: Float) -> Float {
        min(max(speed, minSpeed), maxSpeed)
    }

    func speed(forCharacter name: String) -> Float {
        Self.clamp(characterSpeeds[name] ?? Self.defaultSpeed)
    }

    /// What the engine is actually asked for: the character's own pace scaled
    /// by the script-wide multiplier, clamped so the product stays sane.
    func effectiveSpeed(forCharacter name: String) -> Float {
        Self.clamp(speed(forCharacter: name) * Self.clamp(overallSpeed))
    }

    var effectiveNarratorSpeed: Float {
        Self.clamp(Self.clamp(narratorSpeed) * Self.clamp(overallSpeed))
    }

    // Casts persisted before speeds existed decode without these keys. The
    // synthesised Codable init would reject them outright (a default value does
    // NOT make a key optional at decode time), so decode them permissively.
    private enum CodingKeys: String, CodingKey {
        case characterVoices, narratorVoice, characterSpeeds, narratorSpeed, overallSpeed
    }

    init(
        characterVoices: [String: String],
        narratorVoice: String,
        characterSpeeds: [String: Float] = [:],
        narratorSpeed: Float = defaultSpeed,
        overallSpeed: Float = defaultSpeed
    ) {
        self.characterVoices = characterVoices
        self.narratorVoice = narratorVoice
        self.characterSpeeds = characterSpeeds
        self.narratorSpeed = narratorSpeed
        self.overallSpeed = overallSpeed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        characterVoices = try container.decode([String: String].self, forKey: .characterVoices)
        narratorVoice = try container.decode(String.self, forKey: .narratorVoice)
        characterSpeeds = try container.decodeIfPresent(
            [String: Float].self, forKey: .characterSpeeds
        ) ?? [:]
        narratorSpeed = try container.decodeIfPresent(
            Float.self, forKey: .narratorSpeed
        ) ?? Self.defaultSpeed
        overallSpeed = try container.decodeIfPresent(
            Float.self, forKey: .overallSpeed
        ) ?? Self.defaultSpeed
    }
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
