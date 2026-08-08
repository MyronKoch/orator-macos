import Foundation

/// One placed piece of speech on the timeline.
///
/// Model adapted from Voicebox's `StoryItem` (MIT, github.com/jamiepine/voicebox):
/// absolute `startMS` placement, a 0-indexed `track` row, and trim offsets that
/// hide the leading/trailing portions of the rendered source WITHOUT destroying
/// it. Trims are therefore non-destructive and fully reversible.
///
/// Orator difference: a clip carries the TEXT and VOICE that produced it, not a
/// reference to a pre-rendered file. That is what lets a screenplay auto-populate
/// the timeline, and lets a clip be re-synthesized after its voice or text changes.
struct TimelineClip: Identifiable, Codable, Sendable, Equatable {
    var id: UUID = UUID()
    /// The line as spoken.
    var text: String
    /// Namespaced voice id (`af_heart`, `piper:amy`, `cf:aura-2:thalia`).
    var voiceID: String
    /// Per-clip rate; nil uses the engine default.
    var speed: Float?
    /// Character name from the script ("SARAH"), or "Narrator" for action lines.
    var speaker: String

    /// 0-indexed row. Clips on the SAME track may not overlap; clips on
    /// DIFFERENT tracks play concurrently.
    var track: Int
    /// Absolute position on the timeline where this clip starts playing.
    var startMS: Int
    /// Milliseconds hidden from the head of the rendered audio.
    var trimStartMS: Int = 0
    /// Milliseconds hidden from the tail of the rendered audio.
    var trimEndMS: Int = 0
    /// Full duration of the rendered audio BEFORE trimming. Zero until the clip
    /// has been synthesized (the UI then shows a placeholder width).
    var sourceDurationMS: Int = 0

    /// Audible length after trimming.
    var durationMS: Int { max(0, sourceDurationMS - trimStartMS - trimEndMS) }
    /// Absolute end position.
    var endMS: Int { startMS + durationMS }

    /// Whether this clip has been rendered yet.
    var isRendered: Bool { sourceDurationMS > 0 }
}

/// A multi-track arrangement of spoken clips.
///
/// Pure value type: every mutation is a plain function of the current state, so
/// undo is a matter of keeping previous copies and the audio layer can render a
/// snapshot without locking.
struct Timeline: Codable, Sendable, Equatable {
    var clips: [TimelineClip] = []
    /// Rows to display, at least one more than the highest occupied track so
    /// there is always an empty row to drag into.
    var trackCount: Int = 3

    /// Gap inserted after the last clip when appending without explicit timing.
    /// (Voicebox uses the same 200 ms breath.)
    static let autoGapMS = 200

    // MARK: - Queries

    var totalDurationMS: Int { clips.map(\.endMS).max() ?? 0 }

    func clips(onTrack track: Int) -> [TimelineClip] {
        clips.filter { $0.track == track }.sorted { $0.startMS < $1.startMS }
    }

    func clip(id: UUID) -> TimelineClip? { clips.first { $0.id == id } }

    /// Distinct speakers in first-appearance order - the track legend.
    var speakerOrder: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for clip in clips.sorted(by: { $0.track < $1.track }) where !seen.contains(clip.speaker) {
            seen.insert(clip.speaker)
            order.append(clip.speaker)
        }
        return order
    }

    /// Label for a row: the speaker who owns it, else a generic name.
    func label(forTrack track: Int) -> String {
        clips(onTrack: track).first?.speaker ?? "Track \(track + 1)"
    }

    // MARK: - Mutations

    mutating func add(_ clip: TimelineClip) {
        clips.append(clip)
        growTracksIfNeeded(for: clip.track)
    }

    /// Append to the end of everything, after the standard gap.
    mutating func append(_ clip: TimelineClip, toTrack track: Int) {
        var placed = clip
        placed.track = track
        placed.startMS = totalDurationMS == 0 ? 0 : totalDurationMS + Self.autoGapMS
        add(placed)
    }

    mutating func remove(id: UUID) {
        clips.removeAll { $0.id == id }
    }

    mutating func update(_ clip: TimelineClip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index] = clip
        growTracksIfNeeded(for: clip.track)
    }

    /// Move a clip, clamping to t>=0 and REFUSING a move that would overlap
    /// another clip on the destination track (the invariant that keeps one voice
    /// from talking over itself). Returns true if the move was applied.
    @discardableResult
    mutating func move(id: UUID, toTrack track: Int, startMS: Int) -> Bool {
        guard var clip = clip(id: id) else { return false }
        let target = max(0, startMS)
        guard !wouldOverlap(id: id, track: track, startMS: target, durationMS: clip.durationMS) else {
            return false
        }
        clip.track = max(0, track)
        clip.startMS = target
        update(clip)
        return true
    }

    /// The nearest legal start on `track` at or before `startMS`, used to snap a
    /// dropped clip out of an overlap instead of rejecting the drag outright.
    func nearestFreeStart(id: UUID, track: Int, startMS: Int, durationMS: Int) -> Int? {
        guard durationMS > 0 else { return max(0, startMS) }
        if !wouldOverlap(id: id, track: track, startMS: max(0, startMS), durationMS: durationMS) {
            return max(0, startMS)
        }
        // Try butting up against each neighbour's edges, nearest first.
        var candidates: [Int] = [0]
        for other in clips(onTrack: track) where other.id != id {
            candidates.append(other.endMS)
            candidates.append(max(0, other.startMS - durationMS))
        }
        return candidates
            .filter { !wouldOverlap(id: id, track: track, startMS: $0, durationMS: durationMS) }
            .min { abs($0 - startMS) < abs($1 - startMS) }
    }

    func wouldOverlap(id: UUID, track: Int, startMS: Int, durationMS: Int) -> Bool {
        let end = startMS + durationMS
        return clips.contains { other in
            other.id != id
                && other.track == track
                && startMS < other.endMS
                && end > other.startMS
        }
    }

    /// Trim by dragging an edge. `deltaMS` > 0 shortens. Trims are clamped so a
    /// clip can never invert, and the head-trim moves `startMS` with the edge so
    /// the audio under the cursor stays put.
    mutating func trim(id: UUID, headDeltaMS: Int = 0, tailDeltaMS: Int = 0) {
        guard var clip = clip(id: id), clip.isRendered else { return }
        let minimum = 50 // never trim a clip below 50 ms
        if headDeltaMS != 0 {
            let maxHead = clip.sourceDurationMS - clip.trimEndMS - minimum
            let newTrim = min(max(0, clip.trimStartMS + headDeltaMS), max(0, maxHead))
            clip.startMS = max(0, clip.startMS + (newTrim - clip.trimStartMS))
            clip.trimStartMS = newTrim
        }
        if tailDeltaMS != 0 {
            let maxTail = clip.sourceDurationMS - clip.trimStartMS - minimum
            clip.trimEndMS = min(max(0, clip.trimEndMS + tailDeltaMS), max(0, maxTail))
        }
        update(clip)
    }

    /// Copy a clip onto the first free spot after the original.
    @discardableResult
    mutating func duplicate(id: UUID) -> UUID? {
        guard let source = clip(id: id) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.startMS = nearestFreeStart(
            id: copy.id, track: source.track,
            startMS: source.endMS + Self.autoGapMS, durationMS: source.durationMS
        ) ?? source.endMS + Self.autoGapMS
        add(copy)
        return copy.id
    }

    private mutating func growTracksIfNeeded(for track: Int) {
        trackCount = max(trackCount, track + 2)
    }

    // MARK: - Auto-layout from a cast script

    /// Build a timeline from auto-cast script segments: ONE TRACK PER VOICE, in
    /// first-appearance order, clips sequential in dialogue order.
    ///
    /// This is the piece Voicebox does not have - their editor is assembled by
    /// hand. Here a screenplay lands pre-arranged, and the track a line goes on
    /// is decided by who says it.
    ///
    /// Durations are unknown until synthesis, so clips are laid out end-to-end by
    /// `estimatedDurationMS` and re-flowed by `relayoutSequentially()` once the
    /// real durations arrive.
    static func fromCast(segments: [SpeechSegment]) -> Timeline {
        var timeline = Timeline(clips: [], trackCount: 1)
        // Keyed by SPEAKER, not voice: two characters cast to the same voice
        // still deserve their own row, and the row label is the character.
        var trackForSpeaker: [String: Int] = [:]
        var cursor = 0

        for segment in segments {
            let speaker = segment.speaker ?? "Narrator"
            let track: Int
            if let existing = trackForSpeaker[speaker] {
                track = existing
            } else {
                track = trackForSpeaker.count
                trackForSpeaker[speaker] = track
            }
            let duration = estimatedDurationMS(for: segment.text, speed: segment.speed)
            let clip = TimelineClip(
                text: segment.text,
                voiceID: segment.voiceName,
                speed: segment.speed,
                speaker: speaker,
                track: track,
                startMS: cursor,
                sourceDurationMS: duration
            )
            timeline.add(clip)
            cursor += duration + autoGapMS
        }
        timeline.trackCount = max(timeline.trackCount, trackForSpeaker.count + 1)
        return timeline
    }

    /// Re-flow every clip end-to-end in current order, preserving track
    /// assignment. Called after synthesis replaces estimates with real
    /// durations, so the arrangement stays gap-consistent.
    mutating func relayoutSequentially() {
        let ordered = clips.sorted { $0.startMS < $1.startMS }
        var cursor = 0
        var relaid: [TimelineClip] = []
        for var clip in ordered {
            clip.startMS = cursor
            cursor += clip.durationMS + Self.autoGapMS
            relaid.append(clip)
        }
        clips = relaid
    }

    /// Rough speech length before synthesis, so the UI can lay out immediately.
    /// ~150 wpm at 1x, floored so a one-word line is still grabbable.
    static func estimatedDurationMS(for text: String, speed: Float?) -> Int {
        let words = max(1, text.split(whereSeparator: \.isWhitespace).count)
        let rate = Double(speed ?? 1.0)
        return max(400, Int(Double(words) / 150.0 * 60_000.0 / max(0.25, rate)))
    }
}
