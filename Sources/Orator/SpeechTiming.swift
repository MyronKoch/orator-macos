import Foundation

/// One spoken token (word or punctuation) inside a synthesized chunk.
///
/// Timestamps come from KokoroSwift's `TimestampPredictor`, are measured in
/// seconds of generated audio, and are RELATIVE TO THE CHUNK's own audio.
/// Convert to utterance-absolute time by adding the owning chunk's `offset`.
/// Punctuation tokens carry no phonemes and therefore no timestamps.
struct WordTiming: Sendable {
    /// Surface text of the token as the G2P tokenizer saw it.
    let text: String
    /// Whitespace that followed the token in the chunk. Joining
    /// `text + whitespace` across all words reconstructs the (preprocessed)
    /// spoken text - alignment against the original chunk string should be
    /// tolerant, not assumed exact.
    let whitespace: String
    /// Chunk-relative start time in seconds; nil for unspoken tokens.
    let start: TimeInterval?
    /// Chunk-relative end time in seconds; nil for unspoken tokens.
    let end: TimeInterval?
}

/// Timing for one synthesized chunk of an utterance, emitted as soon as the
/// chunk's audio has been scheduled on the player.
struct ChunkTiming: Sendable {
    /// Identifies the utterance this chunk belongs to (the value returned by
    /// `OratorEngine.speak(chunks:)`). Consumers must drop timings whose
    /// utterance ID does not match the utterance they started.
    let utteranceID: Int
    /// Zero-based index of this chunk within its utterance.
    let chunkIndex: Int
    /// Total number of chunks in the utterance.
    let chunkCount: Int
    /// The exact text passed to synthesis for this chunk.
    let text: String
    /// Utterance-absolute time at which this chunk's audio begins, in seconds.
    let offset: TimeInterval
    /// Duration of this chunk's audio in seconds.
    let duration: TimeInterval
    /// Per-token timing, in spoken order.
    let words: [WordTiming]
}
