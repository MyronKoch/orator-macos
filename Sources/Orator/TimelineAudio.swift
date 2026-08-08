import AVFoundation
import Foundation

/// Renders a `Timeline` to audio: synthesizes each clip once, caches the PCM,
/// and mixes the arrangement down to a single buffer.
///
/// Mixdown algorithm adapted from Voicebox (MIT): allocate a buffer as long as
/// the furthest clip end, sum each trimmed clip into it at its offset (so
/// overlapping tracks blend), then normalize by the peak if it exceeds 1.0.
///
/// Every clip is rendered at the ENGINE's sample rate (providers are resampled
/// on the way out of `renderSamples`), so clips from Kokoro, Piper and the cloud
/// can share one timeline without any rate bookkeeping here.
final class TimelineAudio: @unchecked Sendable {
    private unowned let engine: OratorEngine
    private let queue = DispatchQueue(label: "app.orator.timeline", qos: .userInitiated)
    private let cacheLock = NSLock()
    /// Rendered PCM keyed by clip identity (text + voice + speed), so editing a
    /// clip's position or trim never forces a re-synthesis.
    private var cache: [String: [Float]] = [:]

    /// Bumped to cancel an in-flight render. The render loop compares each
    /// iteration against the generation it started with and bails when they
    /// diverge, so Stop (or starting a second build) actually halts synthesis
    /// instead of letting a long script grind on in the background.
    private let renderLock = NSLock()
    private var renderGeneration = 0

    /// Cancel any render in flight. Safe to call from the main thread.
    func cancelRender() {
        renderLock.lock(); renderGeneration += 1; renderLock.unlock()
    }

    /// True while a render is running, so the UI can show Cancel instead of Build.
    private(set) var isRendering = false

    private func currentRenderGeneration() -> Int {
        renderLock.lock(); defer { renderLock.unlock() }
        return renderGeneration
    }

    init(engine: OratorEngine) {
        self.engine = engine
    }

    var sampleRate: Double { engine.outputSampleRate }

    private func cacheKey(_ clip: TimelineClip) -> String {
        "\(clip.voiceID)|\(clip.speed ?? -1)|\(clip.text)"
    }

    func cachedSamples(for clip: TimelineClip) -> [Float]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[cacheKey(clip)]
    }

    /// Render every clip that isn't cached yet, reporting progress and handing
    /// back a timeline whose `sourceDurationMS` are now REAL (replacing the
    /// pre-synthesis estimates). Clips that fail to render are left at duration
    /// zero rather than aborting the whole arrangement.
    /// `completion` receives whatever was rendered; `cancelled` is true when the
    /// run was halted early, so the caller can leave the timeline alone rather
    /// than committing a half-rendered arrangement.
    func render(
        _ timeline: Timeline,
        progress: @escaping @MainActor @Sendable (Double) -> Void,
        completion: @escaping @MainActor @Sendable (Timeline, Bool) -> Void
    ) {
        // Starting a render supersedes any previous one.
        cancelRender()
        let generation = currentRenderGeneration()
        isRendering = true
        queue.async { [self] in
            var updated = timeline
            var cancelled = false
            let total = max(1, timeline.clips.count)
            for (index, clip) in timeline.clips.enumerated() {
                guard currentRenderGeneration() == generation else {
                    cancelled = true
                    break
                }
                let key = cacheKey(clip)
                var samples = cachedSamples(for: clip)
                if samples == nil {
                    samples = try? engine.renderSamples(
                        text: clip.text, voiceID: clip.voiceID, speed: clip.speed
                    )
                    // Only cache a REAL result. Caching an empty array would mark
                    // the clip permanently rendered-and-silent, so a transient
                    // provider hiccup could never be retried.
                    if let samples, !samples.isEmpty {
                        cacheLock.lock(); cache[key] = samples; cacheLock.unlock()
                    }
                }
                var resolved = clip
                if let samples, !samples.isEmpty {
                    // Round up: flooring to whole ms then back to frames drops the
                    // trailing partial millisecond of EVERY clip.
                    resolved.sourceDurationMS = Int(
                        (Double(samples.count) / sampleRate * 1000.0).rounded(.up)
                    )
                    // A stale trim from a previous, longer render would invert
                    // the clip - clamp both trims into the new source length.
                    resolved.trimStartMS = min(resolved.trimStartMS, max(0, resolved.sourceDurationMS - 50))
                    resolved.trimEndMS = min(
                        resolved.trimEndMS,
                        max(0, resolved.sourceDurationMS - resolved.trimStartMS - 50)
                    )
                } else {
                    // Render FAILED. fromCast seeded an estimate, which would
                    // otherwise leave a normal-looking clip that occupies time and
                    // plays nothing. Zero it so it reads as unrendered.
                    resolved.sourceDurationMS = 0
                    resolved.trimStartMS = 0
                    resolved.trimEndMS = 0
                }
                updated.update(resolved)
                let fraction = Double(index + 1) / Double(total)
                DispatchQueue.main.async { progress(fraction) }
            }
            let result = updated
            let wasCancelled = cancelled
            DispatchQueue.main.async { [self] in
                // Only clear the flag if no NEWER render has started since.
                if currentRenderGeneration() == generation { isRendering = false }
                completion(result, wasCancelled)
            }
        }
    }

    /// Sum the arrangement into one buffer. Requires every clip to be rendered
    /// (call `render` first); unrendered clips are skipped.
    func mixdown(_ timeline: Timeline) -> [Float] {
        let totalMS = timeline.totalDurationMS
        guard totalMS > 0 else { return [] }
        let totalFrames = Int(Double(totalMS) / 1000.0 * sampleRate) + 1
        var buffer = [Float](repeating: 0, count: totalFrames)

        for clip in timeline.clips {
            guard clip.isRendered, let samples = cachedSamples(for: clip), !samples.isEmpty else {
                continue
            }
            // Clamp every index to >= 0 before it touches an array. A clip with a
            // negative startMS or trim (from a bad edit or a decoded document)
            // would otherwise produce a negative index and TRAP, taking the app
            // down mid-export.
            let headFrames = max(0, Int(Double(clip.trimStartMS) / 1000.0 * sampleRate))
            let audibleFrames = max(0, Int(Double(clip.durationMS) / 1000.0 * sampleRate))
            let offset = max(0, Int(Double(clip.startMS) / 1000.0 * sampleRate))
            guard audibleFrames > 0, headFrames < samples.count, offset < totalFrames else {
                continue
            }

            let available = min(audibleFrames, samples.count - headFrames)
            let writable = min(available, max(0, totalFrames - offset))
            guard writable > 0 else { continue }
            let gain = timeline.gain(forTrack: clip.track)
            for frame in 0..<writable {
                buffer[offset + frame] += samples[headFrames + frame] * gain
            }
        }

        // Overlapping tracks can sum past full scale - normalize rather than clip.
        if let peak = buffer.map({ abs($0) }).max(), peak > 1.0 {
            let scale = 1.0 / peak
            for index in buffer.indices { buffer[index] *= scale }
        }
        return buffer
    }

    /// Mix down and write to an .m4a for "Export Audio".
    func export(
        _ timeline: Timeline,
        to url: URL,
        completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void
    ) {
        queue.async { [self] in
            func finish(_ result: Result<URL, Error>) {
                DispatchQueue.main.async { completion(result) }
            }
            let samples = mixdown(timeline)
            guard !samples.isEmpty else {
                finish(.failure(TimelineAudioError.nothingToExport)); return
            }
            do {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                // Scoped so the AVAudioFile is released (container finalized)
                // before success is reported - same reason as synthesizeToFile.
                do {
                    let file = try AVAudioFile(forWriting: url, settings: settings)
                    let format = file.processingFormat
                    // Write in slices so a long arrangement doesn't need one
                    // giant PCM buffer allocation on top of the mixdown.
                    let sliceFrames = 32_768
                    var position = 0
                    while position < samples.count {
                        let count = min(sliceFrames, samples.count - position)
                        guard let buffer = AVAudioPCMBuffer(
                            pcmFormat: format, frameCapacity: AVAudioFrameCount(count)
                        ) else { break }
                        buffer.frameLength = AVAudioFrameCount(count)
                        samples[position..<(position + count)].withUnsafeBufferPointer { src in
                            UnsafeMutableRawPointer(buffer.floatChannelData![0]).copyMemory(
                                from: UnsafeRawPointer(src.baseAddress!),
                                byteCount: count * MemoryLayout<Float>.stride
                            )
                        }
                        try file.write(from: buffer)
                        position += count
                    }
                }
                finish(.success(url))
            } catch {
                finish(.failure(error))
            }
        }
    }

    /// Peak envelope for drawing a clip's waveform, downsampled to `buckets`.
    /// Returns the AUDIBLE (post-trim) region only, so the drawn shape always
    /// matches what the clip actually plays.
    func envelope(for clip: TimelineClip, buckets: Int) -> [Float] {
        guard buckets > 0, let samples = cachedSamples(for: clip), !samples.isEmpty else { return [] }
        let head = min(Int(Double(clip.trimStartMS) / 1000.0 * sampleRate), samples.count)
        let length = min(
            Int(Double(clip.durationMS) / 1000.0 * sampleRate),
            samples.count - head
        )
        guard length > 0 else { return [] }
        let perBucket = max(1, length / buckets)
        var envelope: [Float] = []
        envelope.reserveCapacity(buckets)
        var index = head
        while index < head + length {
            let end = min(index + perBucket, head + length)
            var peak: Float = 0
            for frame in index..<end { peak = max(peak, abs(samples[frame])) }
            envelope.append(peak)
            index = end
        }
        return envelope
    }
}

enum TimelineAudioError: LocalizedError {
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .nothingToExport: return "There is nothing on the timeline to export."
        }
    }
}
