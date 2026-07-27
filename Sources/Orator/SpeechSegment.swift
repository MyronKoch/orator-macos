import Foundation

/// A span of text to be spoken in a specific voice. Auto-casting produces a
/// sequence of these (narrator + one per detected speaker); the engine chunks
/// each segment's text internally but keeps the segment's voice constant across
/// its chunks. Voices should stay within one language family (all US or all GB)
/// to avoid a G2P reload between segments.
struct SpeechSegment: Sendable {
    let text: String
    let voiceName: String
    /// Speaking rate for this segment. `nil` uses the engine's current speed,
    /// which is what every non-script caller wants. Script mode sets it so one
    /// character can rattle while another takes their time.
    let speed: Float?

    init(text: String, voiceName: String, speed: Float? = nil) {
        self.text = text
        self.voiceName = voiceName
        self.speed = speed
    }
}
