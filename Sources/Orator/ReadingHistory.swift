import Foundation

struct HistoryEntry: Codable, Sendable {
    let title: String
    let text: String
}

/// A small, persistent list of recently read text.
final class ReadingHistory: @unchecked Sendable {

    private static let defaultsKey = "readingHistory"
    private static let maximumEntryCount = 20
    private static let titleLength = 50

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var storedEntries: [HistoryEntry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.defaultsKey),
           let savedEntries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            storedEntries = Array(savedEntries.prefix(Self.maximumEntryCount))
        } else {
            storedEntries = []
        }
    }

    var entries: [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }

        return storedEntries
    }

    func add(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        guard storedEntries.first?.text != text else { return }

        let singleLine = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let entry = HistoryEntry(
            title: String(singleLine.prefix(Self.titleLength)),
            text: text
        )
        storedEntries.insert(entry, at: 0)
        if storedEntries.count > Self.maximumEntryCount {
            storedEntries.removeLast(storedEntries.count - Self.maximumEntryCount)
        }
        persistLocked()
    }

    func clear() {
        lock.lock()
        storedEntries.removeAll()
        persistLocked()
        lock.unlock()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(storedEntries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
