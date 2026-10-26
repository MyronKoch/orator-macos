import AVFoundation

/// Tempo change without a pitch change, for engines with no speed control of
/// their own (Phonon). Renders the samples through `AVAudioUnitTimePitch` in an
/// offline engine, so it runs at CPU speed on the synth queue, not in real time.
enum TimeStretch {
    private static let blockFrames: AVAudioFrameCount = 4096

    /// `rate` > 1 is faster/shorter. Returns the input untouched at ~1x or if
    /// anything in the audio stack refuses (better normal speed than silence).
    static func apply(_ samples: [Float], rate: Float, sampleRate: Double) -> [Float] {
        guard abs(rate - 1) > 0.01, !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return samples }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = rate
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: blockFrames)
            try engine.start()
        } catch {
            oratorLog("time-stretch: engine refused (\(error)); speaking at 1x")
            return samples
        }
        defer { player.stop(); engine.stop() }

        // The unit delays its output by `latency`. Feed silence after the speech
        // so the tail is flushed, then drop that many frames from the front.
        let latencyFrames = Int((timePitch.auAudioUnit.latency * sampleRate).rounded())
        let padded = samples + [Float](repeating: 0, count: latencyFrames * 2 + Int(blockFrames))
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(padded.count)),
              let block = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: blockFrames)
        else { return samples }
        input.frameLength = input.frameCapacity
        padded.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: padded.count) }
        player.scheduleBuffer(input)
        player.play()

        let wanted = Int((Double(samples.count) / Double(rate)).rounded())
        var output: [Float] = []
        output.reserveCapacity(latencyFrames + wanted)
        while output.count < latencyFrames + wanted {
            let frames = min(Int(blockFrames), latencyFrames + wanted - output.count)
            guard (try? engine.renderOffline(AVAudioFrameCount(frames), to: block)) == .success else { break }
            output.append(contentsOf: UnsafeBufferPointer(start: block.floatChannelData![0], count: Int(block.frameLength)))
        }
        return Array(output.dropFirst(latencyFrames))
    }
}
