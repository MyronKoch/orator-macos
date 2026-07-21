import Foundation

/// Layer 2: user-configurable text replacements applied before the built-in
/// expansions and the symbol sanitizer, so users control the long tail of
/// symbols/abbreviations/phrases (e.g. "→" -> "leads to", jargon, custom units).
///
/// Distinct from `Pronunciations` (whole-word "say it like"): these are ordered,
/// may be literal or regex, and can match symbols/phrases that aren't words.
final class UserReplacements: @unchecked Sendable {

    static let shared = UserReplacements()

    struct Rule: Codable, Sendable, Equatable {
        var find: String
        var replace: String
        var isRegex: Bool
        var enabled: Bool

        init(find: String, replace: String, isRegex: Bool = false, enabled: Bool = true) {
            self.find = find
            self.replace = replace
            self.isRegex = isRegex
            self.enabled = enabled
        }
    }

    private static let defaultsKey = "userReplacements.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var storedRules: [Rule]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Rule].self, from: data) {
            storedRules = decoded
        } else {
            storedRules = []
        }
    }

    /// The current ordered rules. Order matters — rules apply top to bottom.
    var rules: [Rule] {
        lock.lock(); defer { lock.unlock() }
        return storedRules
    }

    /// Replace the full ordered rule set (the editor owns ordering).
    func setRules(_ rules: [Rule]) {
        lock.lock()
        storedRules = rules
        persistLocked()
        lock.unlock()
    }

    /// Whether a regex pattern is valid (for the editor to validate on entry).
    static func isValidRegex(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// Apply enabled rules, in order, to `text`. A malformed regex rule is
    /// skipped (never crashes); literal rules are plain case-insensitive
    /// replacements. Runs FIRST in the pipeline, before built-in expansions.
    func apply(to text: String) -> String {
        let snapshot = rules
        guard !snapshot.isEmpty, !text.isEmpty else { return text }

        var result = text
        for rule in snapshot where rule.enabled && !rule.find.isEmpty {
            if rule.isRegex {
                guard let regex = try? NSRegularExpression(pattern: rule.find) else { continue }
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: rule.replace
                )
            } else {
                result = result.replacingOccurrences(
                    of: rule.find,
                    with: rule.replace,
                    options: [.caseInsensitive]
                )
            }
        }
        return result
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(storedRules) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
