import Foundation

/// User-defined, plain-text pronunciation substitutions.
final class Pronunciations: @unchecked Sendable {

    static let shared = Pronunciations()

    private static let defaultsKey = "pronunciations"
    private static let seedEntries = [
        "MLX": "em ell ex",
        "Kokoro": "koh koh roh",
        "macOS": "mac oh ess",
    ]

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var storedEntries: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let saved = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] {
            storedEntries = saved
        } else if defaults.object(forKey: Self.defaultsKey) == nil {
            storedEntries = Self.seedEntries
            defaults.set(Self.seedEntries, forKey: Self.defaultsKey)
        } else {
            storedEntries = [:]
        }
    }

    var entries: [(key: String, value: String)] {
        lock.lock()
        defer { lock.unlock() }

        return storedEntries
            .map { (key: $0.key, value: $0.value) }
            .sorted {
                let order = $0.key.localizedCaseInsensitiveCompare($1.key)
                return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
            }
    }

    func add(key: String, value: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        lock.lock()
        if let existingKey = matchingStoredKey(for: key) {
            storedEntries.removeValue(forKey: existingKey)
        }
        storedEntries[key] = value
        persistLocked()
        lock.unlock()
    }

    func remove(key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        lock.lock()
        if let existingKey = matchingStoredKey(for: key) {
            storedEntries.removeValue(forKey: existingKey)
            persistLocked()
        }
        lock.unlock()
    }

    func apply(to text: String) -> String {
        let snapshot = entries.filter { !$0.key.isEmpty }
        guard !snapshot.isEmpty, !text.isEmpty else { return text }

        // Longest alternatives first ensures a multi-word key wins over one of
        // its component words. Replacing matches from the end keeps ranges valid.
        let alternatives = snapshot
            .sorted { $0.key.count > $1.key.count }
            .map { NSRegularExpression.escapedPattern(for: $0.key) }
            .joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{M}\\p{N}_])"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }

        let matches = regex.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        var result = text

        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let matchedKey = String(result[range])
            guard let replacement = snapshot.first(where: {
                $0.key.caseInsensitiveCompare(matchedKey) == .orderedSame
            })?.value else { continue }
            result.replaceSubrange(range, with: replacement)
        }

        return result
    }

    private func matchingStoredKey(for key: String) -> String? {
        storedEntries.keys.first { $0.caseInsensitiveCompare(key) == .orderedSame }
    }

    private func persistLocked() {
        defaults.set(storedEntries, forKey: Self.defaultsKey)
    }
}
