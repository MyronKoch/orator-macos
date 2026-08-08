import Foundation

/// A saved Orator session: the script, its cast, and the timeline arrangement.
///
/// Written as JSON with the `.orator` extension. Deliberately stores the SOURCE
/// (text + voice per clip) and NOT the rendered audio: a session file stays a
/// few kilobytes instead of hundreds of megabytes, and reopening it re-renders
/// from the current engine, so a session made with Piper voices still opens for
/// someone who later switches to Kokoro or a cloud voice.
///
/// Audio is exported separately (Export Audio), which is the artifact you hand
/// to someone else; this is the editable project.
struct TimelineDocument: Codable, Sendable {
    /// Bumped when the format changes incompatibly. Readers refuse a version
    /// they do not understand rather than silently mangling it.
    static let currentVersion = 1

    var version: Int = TimelineDocument.currentVersion
    /// The raw script text, so reopening restores the editor exactly.
    var scriptText: String
    /// Character-to-voice assignments and per-character speeds.
    var cast: ScriptCast
    /// The arrangement: clip placement, trims, track gains.
    var timeline: Timeline
    /// Free-form title shown in the window, defaulting to the file name.
    var title: String?
    /// ISO-8601 timestamps, informational only.
    var savedAt: Date = Date()

    static let fileExtension = "orator"

    init(scriptText: String, cast: ScriptCast, timeline: Timeline, title: String? = nil) {
        self.scriptText = scriptText
        self.cast = cast
        self.timeline = timeline
        self.title = title
    }

    /// Tolerant decode so a file written by an older build still opens.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.currentVersion else {
            throw TimelineDocumentError.unsupportedVersion(version)
        }
        scriptText = try container.decodeIfPresent(String.self, forKey: .scriptText) ?? ""
        cast = try container.decodeIfPresent(ScriptCast.self, forKey: .cast)
            ?? ScriptCast(characterVoices: [:], narratorVoice: "")
        timeline = try container.decodeIfPresent(Timeline.self, forKey: .timeline) ?? Timeline()
        title = try container.decodeIfPresent(String.self, forKey: .title)
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
    }

    // MARK: - Disk

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Write to a sibling temp file and swap, so a crash mid-write cannot
        // leave the user with a truncated session where their work used to be.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).saving")
        try encoder.encode(self).write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    static func read(from url: URL) throws -> TimelineDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TimelineDocument.self, from: Data(contentsOf: url))
    }
}

enum TimelineDocumentError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This session was saved by a newer version of Orator (format \(version)). Update Orator to open it."
        }
    }
}
