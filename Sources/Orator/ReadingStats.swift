import Foundation

/// A snapshot of everything the Dashboard renders. Pure value type so the UI
/// can be handed one struct and never touch the store's internals.
struct ReadingStatsSnapshot: Sendable {
    struct DayPoint: Sendable { let date: Date; let weekdayInitial: String; let words: Int; let isToday: Bool }
    struct Ranked: Sendable { let name: String; let words: Int; let fraction: Double }
    struct Longest: Sendable { let title: String; let words: Int; let seconds: Double; let voice: String }

    var lifetimeWords = 0
    var lifetimeSeconds: Double = 0
    var totalReads = 0
    var castReads = 0
    var wordsToday = 0
    var currentStreakDays = 0
    var bestStreakDays = 0
    var weeklyGoalWords = 0
    var wordsThisWeek = 0                 // rolling last 7 days
    var week: [DayPoint] = []             // oldest → today, exactly 7 points
    var topSources: [Ranked] = []
    var topVoices: [Ranked] = []
    var longest: Longest?

    var averageWordsPerRead: Int { totalReads > 0 ? lifetimeWords / totalReads : 0 }
    var weeklyGoalFraction: Double { weeklyGoalWords > 0 ? min(1, Double(wordsThisWeek) / Double(weeklyGoalWords)) : 0 }
}

/// Local, private reading analytics. Stores one compact bucket per calendar
/// day (words/reads/seconds + per-app and per-voice word tallies), which
/// compresses indefinitely while still yielding streaks, weekly totals, and
/// top-N breakdowns. Nothing here leaves the machine.
///
/// Threading mirrors the app's other stores: `@unchecked Sendable` guarded by
/// an `NSLock`. Day keys and "today" use the current calendar/timezone; an
/// injectable clock keeps the logic unit-testable.
final class ReadingStats: @unchecked Sendable {

    struct DayBucket: Codable {
        var words = 0
        var chars = 0
        var seconds: Double = 0
        var reads = 0
        var perApp: [String: Int] = [:]
        var perVoice: [String: Int] = [:]
    }

    private struct LongestRead: Codable {
        var title: String
        var words: Int
        var seconds: Double
        var voice: String
    }

    private static let bucketsKey = "readingStats.buckets.v1"
    private static let bestStreakKey = "readingStats.bestStreak.v1"
    private static let longestKey = "readingStats.longest.v1"
    private static let weeklyGoalKey = "readingStats.weeklyGoal.v1"
    private static let defaultWeeklyGoal = 5_000
    /// Words per minute used to estimate listen time when we lack a real
    /// duration; ~155 wpm is a natural TTS listening pace at 1.0x.
    static let baselineWPM: Double = 155

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var buckets: [String: DayBucket]
    private var bestStreak: Int
    private var longest: LongestRead?

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now

        if let data = defaults.data(forKey: Self.bucketsKey),
           let decoded = try? JSONDecoder().decode([String: DayBucket].self, from: data) {
            buckets = decoded
        } else {
            buckets = [:]
        }
        bestStreak = defaults.integer(forKey: Self.bestStreakKey)
        if let data = defaults.data(forKey: Self.longestKey),
           let decoded = try? JSONDecoder().decode(LongestRead.self, from: data) {
            longest = decoded
        }
    }

    // MARK: - Recording

    /// Record one read. `estSeconds` may be nil, in which case listen time is
    /// estimated from the word count at the baseline pace divided by speed.
    func record(
        text: String,
        sourceApp: String?,
        voiceName: String,
        cast: Bool,
        speed: Float,
        estSeconds: Double? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let words = trimmed.split { $0.isWhitespace || $0.isNewline }.count
        let chars = trimmed.count
        let seconds = estSeconds
            ?? (Double(words) / Self.baselineWPM * 60.0 / Double(max(0.1, speed)))

        lock.lock()
        defer { lock.unlock() }

        let key = dayKey(for: now())
        var bucket = buckets[key] ?? DayBucket()
        bucket.words += words
        bucket.chars += chars
        bucket.seconds += seconds
        bucket.reads += 1
        if let app = sourceApp, !app.isEmpty { bucket.perApp[app, default: 0] += words }
        bucket.perVoice[voiceName, default: 0] += words
        // Cast reads are tallied under a reserved sentinel key so the snapshot
        // can sum them without a schema change; the "__" prefix keeps it out
        // of the per-voice ranking.
        if cast { bucket.perVoice["__castReads", default: 0] += 1 }
        buckets[key] = bucket

        // Longest single read (by words).
        if longest == nil || words > (longest?.words ?? 0) {
            longest = LongestRead(
                title: Self.title(from: trimmed),
                words: words,
                seconds: seconds,
                voice: voiceName
            )
        }

        // Best streak may extend today.
        let streak = currentStreakLocked()
        if streak > bestStreak { bestStreak = streak }

        persistLocked()
    }

    // MARK: - Snapshot

    func snapshot() -> ReadingStatsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var snap = ReadingStatsSnapshot()
        var appTotals: [String: Int] = [:]
        var voiceTotals: [String: Int] = [:]
        var castReads = 0

        for (_, bucket) in buckets {
            snap.lifetimeWords += bucket.words
            snap.lifetimeSeconds += bucket.seconds
            snap.totalReads += bucket.reads
            for (app, w) in bucket.perApp where !app.hasPrefix("__") {
                appTotals[app, default: 0] += w
            }
            for (voice, w) in bucket.perVoice {
                if voice == "__castReads" { castReads += w; continue }
                if voice.hasPrefix("__") { continue }
                voiceTotals[voice, default: 0] += w
            }
        }
        snap.castReads = castReads

        let todayKey = dayKey(for: now())
        snap.wordsToday = buckets[todayKey]?.words ?? 0
        snap.currentStreakDays = currentStreakLocked()
        snap.bestStreakDays = max(bestStreak, snap.currentStreakDays)
        snap.weeklyGoalWords = weeklyGoalLocked()

        // Rolling last 7 days, oldest → today.
        let today = calendar.startOfDay(for: now())
        let initials = ["S", "M", "T", "W", "T", "F", "S"]
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let words = buckets[dayKey(for: day)]?.words ?? 0
            snap.wordsThisWeek += words
            let weekdayIndex = (calendar.component(.weekday, from: day) - 1) % 7
            snap.week.append(ReadingStatsSnapshot.DayPoint(
                date: day,
                weekdayInitial: initials[weekdayIndex],
                words: words,
                isToday: offset == 0
            ))
        }

        snap.topSources = rank(appTotals, total: snap.lifetimeWords, limit: 5)
        snap.topVoices = rank(voiceTotals, total: snap.lifetimeWords, limit: 4)
        if let longest {
            snap.longest = .init(title: longest.title, words: longest.words, seconds: longest.seconds, voice: longest.voice)
        }
        return snap
    }

    // MARK: - Weekly goal

    var weeklyGoalWords: Int {
        get { lock.lock(); defer { lock.unlock() }; return weeklyGoalLocked() }
        set {
            lock.lock(); defer { lock.unlock() }
            defaults.set(max(0, newValue), forKey: Self.weeklyGoalKey)
        }
    }

    func clear() {
        lock.lock()
        buckets.removeAll()
        bestStreak = 0
        longest = nil
        defaults.removeObject(forKey: Self.bucketsKey)
        defaults.removeObject(forKey: Self.bestStreakKey)
        defaults.removeObject(forKey: Self.longestKey)
        lock.unlock()
    }

    // MARK: - Internals (call with lock held)

    private func weeklyGoalLocked() -> Int {
        let stored = defaults.object(forKey: Self.weeklyGoalKey) as? Int
        return stored ?? Self.defaultWeeklyGoal
    }

    /// Consecutive days up to and including today with at least one read. If
    /// today has none yet, the streak still counts through yesterday.
    private func currentStreakLocked() -> Int {
        let today = calendar.startOfDay(for: now())
        var streak = 0
        var cursor = today
        var countedToday = false

        // Today is optional: a streak of prior days shouldn't reset just
        // because you haven't read yet today.
        if hasReads(on: today) {
            streak += 1
            countedToday = true
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return streak }
        cursor = yesterday
        while hasReads(on: cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        // If nothing today and nothing yesterday, streak is 0.
        if !countedToday && streak == 0 { return 0 }
        return streak
    }

    private func hasReads(on day: Date) -> Bool {
        (buckets[dayKey(for: day)]?.reads ?? 0) > 0
    }

    private func rank(_ totals: [String: Int], total: Int, limit: Int) -> [ReadingStatsSnapshot.Ranked] {
        let denom = Double(max(1, total))
        return totals
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit)
            .map { .init(name: $0.key, words: $0.value, fraction: Double($0.value) / denom) }
    }

    private func dayKey(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func title(from text: String) -> String {
        let singleLine = text.split { $0.isWhitespace || $0.isNewline }.joined(separator: " ")
        return String(singleLine.prefix(60))
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(buckets) {
            defaults.set(data, forKey: Self.bucketsKey)
        }
        defaults.set(bestStreak, forKey: Self.bestStreakKey)
        if let longest, let data = try? JSONEncoder().encode(longest) {
            defaults.set(data, forKey: Self.longestKey)
        }
    }
}
