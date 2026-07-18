import Foundation

/// Always-on recorder for the document and timings behind live speech.
///
/// All playback entry points go through this object, making it the sole owner
/// of `OratorEngine.onChunkTiming`. Reader sessions observe this shared state
/// instead of installing utterance-specific timing callbacks themselves.
@MainActor
final class SpeechTimeline {

    struct Utterance {
        let id: Int
        let chunks: [String]
        var chunkVoices: [String]?
        let baseIndex: Int
        var timings: [Int: ChunkTiming]
    }

    enum Event {
        case utteranceStarted
        case chunkTimed(globalIndex: Int)
        case utteranceEnded
    }

    private let engine: OratorEngine
    private var speechFinishedObserver: NSObjectProtocol?

    private(set) var current: Utterance?
    var isActive: Bool { engine.isSpeaking }
    var onEvent: (@MainActor (Event) -> Void)?

    init(engine: OratorEngine) {
        self.engine = engine

        engine.onChunkTiming = { [weak self] timing in
            MainActor.assumeIsolated {
                guard let self,
                      timing.utteranceID == self.current?.id,
                      let baseIndex = self.current?.baseIndex
                else { return }

                let globalIndex = baseIndex + timing.chunkIndex
                self.current?.timings[globalIndex] = timing
                self.onEvent?(.chunkTimed(globalIndex: globalIndex))
            }
        }

        speechFinishedObserver = NotificationCenter.default.addObserver(
            forName: .oratorSpeechFinished,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.current != nil, !self.engine.isSpeaking else { return }
                self.onEvent?(.utteranceEnded)
            }
        }
    }

    func speak(text: String) throws {
        try speak(chunks: TextChunker.chunk(text), from: 0)
    }

    func speak(segments: [SpeechSegment]) throws {
        var chunks: [String] = []
        var chunkVoices: [String] = []
        for segment in segments {
            let segmentChunks = TextChunker.chunk(segment.text)
            chunks.append(contentsOf: segmentChunks)
            chunkVoices.append(contentsOf: repeatElement(
                segment.voiceName,
                count: segmentChunks.count
            ))
        }
        guard !chunks.isEmpty else { return }

        engine.stop()
        let utteranceID = try engine.speak(segments: segments)
        guard utteranceID >= 0 else { return }

        current = Utterance(
            id: utteranceID,
            chunks: chunks,
            chunkVoices: chunkVoices,
            baseIndex: 0,
            timings: [:]
        )
        onEvent?(.utteranceStarted)
    }

    func speak(chunks: [String], from index: Int) throws {
        guard chunks.indices.contains(index) else { return }

        engine.stop()
        let utteranceID = try engine.speak(chunks: Array(chunks[index...]))
        guard utteranceID >= 0 else { return }

        current = Utterance(
            id: utteranceID,
            chunks: chunks,
            chunkVoices: nil,
            baseIndex: index,
            timings: [:]
        )
        onEvent?(.utteranceStarted)
    }

    func replay(fromChunk index: Int, fallbackChunks: [String]? = nil) throws {
        let utterance: Utterance
        if let current, fallbackChunks == nil || current.chunks == fallbackChunks {
            utterance = current
        } else if let fallbackChunks {
            utterance = Utterance(
                id: -1,
                chunks: fallbackChunks,
                chunkVoices: nil,
                baseIndex: 0,
                timings: [:]
            )
        } else {
            return
        }
        guard utterance.chunks.indices.contains(index) else { return }

        engine.stop()
        let utteranceID: Int
        if let voices = utterance.chunkVoices {
            guard voices.count == utterance.chunks.count else {
                assertionFailure("SpeechTimeline chunks and chunkVoices must stay aligned")
                return
            }
            // One segment per stored chunk (NOT merged): the engine re-chunks
            // each segment via TextChunker.chunk, and a single stored chunk
            // re-chunks to itself, so ChunkTiming indices stay exactly aligned
            // with `chunks[index...]`. Merging same-voice chunks would let the
            // chunker re-pack across the stored boundaries and drift the
            // Reader highlight after a cast jump.
            let segments = zip(utterance.chunks[index...], voices[index...]).map {
                SpeechSegment(text: $0, voiceName: $1)
            }
            utteranceID = try engine.speak(segments: segments)
        } else {
            utteranceID = try engine.speak(chunks: Array(utterance.chunks[index...]))
        }
        guard utteranceID >= 0 else { return }

        current = Utterance(
            id: utteranceID,
            chunks: utterance.chunks,
            chunkVoices: utterance.chunkVoices,
            baseIndex: index,
            timings: [:]
        )
        onEvent?(.utteranceStarted)
    }
}
