import Foundation

/// Voice and speed overrides associated with individual applications.
struct Profile: Codable, Sendable {
    let appName: String
    let voice: String
    let speed: Float
}

final class AppVoiceProfiles: @unchecked Sendable {

    private static let defaultsKey = "appVoiceProfiles"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var storedProfiles: [String: Profile]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let saved = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Profile].self, from: saved) {
            storedProfiles = decoded
        } else {
            storedProfiles = [:]
        }
    }

    func profile(for bundleID: String) -> Profile? {
        lock.lock()
        defer { lock.unlock() }

        return storedProfiles[bundleID]
    }

    func set(bundleID: String, appName: String, voice: String, speed: Float) {
        lock.lock()
        storedProfiles[bundleID] = Profile(appName: appName, voice: voice, speed: speed)
        persistLocked()
        lock.unlock()
    }

    func remove(bundleID: String) {
        lock.lock()
        if storedProfiles.removeValue(forKey: bundleID) != nil {
            persistLocked()
        }
        lock.unlock()
    }

    var all: [(bundleID: String, profile: Profile)] {
        lock.lock()
        defer { lock.unlock() }

        return storedProfiles
            .map { (bundleID: $0.key, profile: $0.value) }
            .sorted {
                let order = $0.profile.appName.localizedCaseInsensitiveCompare($1.profile.appName)
                return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
            }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(storedProfiles) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
