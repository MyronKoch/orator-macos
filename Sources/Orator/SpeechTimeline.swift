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

    func speak(chunks: [String], from index: Int) throws {
        guard chunks.indices.contains(index) else { return }

        engine.stop()
        let utteranceID = try engine.speak(chunks: Array(chunks[index...]))
        guard utteranceID >= 0 else { return }

        current = Utterance(
            id: utteranceID,
            chunks: chunks,
            baseIndex: index,
            timings: [:]
        )
        onEvent?(.utteranceStarted)
    }
}
