import AppKit

/// How much a voice is a favorite. Lower raw value ranks first in the pickers'
/// Favorites section.
enum FavoriteLevel: Int, CaseIterable, Sendable {
    case gold = 1
    case silver = 2
    case bronze = 3

    var title: String {
        switch self {
        case .gold: return "Gold"
        case .silver: return "Silver"
        case .bronze: return "Bronze"
        }
    }

    /// Fixed colours (not system colours) so the three tiers read the same in
    /// light and dark mode.
    var color: NSColor {
        switch self {
        case .gold: return NSColor(srgbRed: 0.96, green: 0.74, blue: 0.10, alpha: 1)
        case .silver: return NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)
        case .bronze: return NSColor(srgbRed: 0.78, green: 0.47, blue: 0.22, alpha: 1)
        }
    }

    /// A filled star in this tier's colour, sized for menu rows.
    var star: NSImage? { FavoriteLevel.star(color: color) }

    static func star(color: NSColor?, filled: Bool = true) -> NSImage? {
        let base = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: "Favorite")
        var config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        return base?.withSymbolConfiguration(config)
    }
}

/// Voices the user starred, by namespaced (or bare Kokoro) voice id. Stored in
/// UserDefaults; posts `.oratorFavoritesChanged` so every picker can redraw.
enum VoiceFavorites {
    private static let key = "voiceFavorites"

    static func level(for voiceID: String) -> FavoriteLevel? {
        stored()[voiceID].flatMap(FavoriteLevel.init(rawValue:))
    }

    static func set(_ level: FavoriteLevel?, for voiceID: String) {
        var map = stored()
        map[voiceID] = level?.rawValue
        UserDefaults.standard.set(map, forKey: key)
        NotificationCenter.default.post(name: .oratorFavoritesChanged, object: nil)
    }

    /// Favorites in `order` (the picker's own voice order), gold first, then
    /// silver, then bronze. Ids not in `order` (uninstalled voices) are skipped.
    static func ranked(in order: [String]) -> [(id: String, level: FavoriteLevel)] {
        let map = stored()
        return FavoriteLevel.allCases.flatMap { level in
            order.filter { map[$0] == level.rawValue }.map { ($0, level) }
        }
    }

    private static func stored() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }
}

extension Notification.Name {
    static let oratorFavoritesChanged = Notification.Name("oratorFavoritesChanged")
}

extension NSMenu {
    /// Stars every voice row (an item whose `representedObject` is a voice id)
    /// with its favorite colour, and puts a Favorites section on top, gold then
    /// silver then bronze. Each favorite row copies its original row's title,
    /// action, target and checkmark, so choosing it behaves identically.
    func applyVoiceFavorites() {
        let voiceRows = items.filter { $0.representedObject is String }
        var firstRow: [String: NSMenuItem] = [:]
        var order: [String] = []
        for row in voiceRows {
            guard let id = row.representedObject as? String else { continue }
            row.image = VoiceFavorites.level(for: id)?.star
            if firstRow[id] == nil { firstRow[id] = row; order.append(id) }
        }
        let favorites = VoiceFavorites.ranked(in: order)
        guard !favorites.isEmpty else { return }

        var index = 0
        let header = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
        header.isEnabled = false
        insertItem(header, at: index); index += 1
        for favorite in favorites {
            guard let original = firstRow[favorite.id] else { continue }
            let row = NSMenuItem(title: original.title, action: original.action, keyEquivalent: "")
            row.target = original.target
            row.state = original.state
            row.representedObject = favorite.id
            row.image = favorite.level.star
            insertItem(row, at: index); index += 1
        }
        insertItem(.separator(), at: index)
    }
}
