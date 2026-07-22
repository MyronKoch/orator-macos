import Foundation

protocol ReaderSpeechEngine: AnyObject {
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    var playbackPosition: TimeInterval? { get }

    func stop()
    func pause()
    func resume()
}

extension OratorEngine: ReaderSpeechEngine {}

/// Main-thread model for a Reader document and its playback timeline.
@MainActor
final class ReaderSession {

    enum State {
        case idle
        case playing
        case paused
    }

    private struct AlignedWord {
        let characterRange: NSRange
        let start: TimeInterval
        let end: TimeInterval
        let chunkIndex: Int
    }

    private struct TimedChunk {
        let index: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    private let timeline: SpeechTimeline
    private let engine: any ReaderSpeechEngine
    private var notificationObservers: [NSObjectProtocol] = []
    private var positionTimer: Timer?
    private var alignedWords: [AlignedWord] = []
    private var timedChunks: [TimedChunk] = []
    private var activeWord: AlignedWord?
    private var lastKnownPosition: TimeInterval = 0

    /// The player reports rendered-sample position, which runs ahead of the
    /// audible output by the buffer/output latency. Nudge the word lookup back
    /// so the highlight lands on the word you actually hear (tune to taste).
    private static let highlightLatencyCompensation: TimeInterval = 0.12

    private(set) var text = ""
    private(set) var chunks: [String] = []
    private(set) var chunkRanges: [NSRange] = []
    private(set) var state: State = .idle
    private(set) var currentChunkIndex: Int?

    var chunkCount: Int { chunks.count }

    var onActiveWordChanged: (@MainActor (NSRange?) -> Void)?
    var onStateChanged: (@MainActor (State) -> Void)?
    var onProgressChanged: (@MainActor (_ elapsed: TimeInterval, _ chunkIndex: Int?) -> Void)?
    var onDocumentChanged: (@MainActor () -> Void)?

    init(timeline: SpeechTimeline, engine: any ReaderSpeechEngine) {
        self.timeline = timeline
        self.engine = engine

        timeline.onEvent = { [weak self] event in
            self?.receive(event)
        }
        observeSpeechNotifications()
    }

    /// Loads a passive fallback document without disturbing shared playback.
    func load(rawText: String) {
        resetPlaybackTracking(clearCurrentChunk: true, resetPosition: true)
        // Formatted display (source line breaks preserved) + per-chunk spoken
        // text and exact display ranges. The word-highlight's literal search
        // still finds plain words in the display; transformed tokens (numbers/
        // symbols) simply don't highlight.
        let document = TextChunker.readerChunks(rawText)
        text = document.display
        chunks = document.chunks.map { $0.spoken }
        chunkRanges = document.chunks.map { $0.displayRange }
        setState(.idle)
        onDocumentChanged?()
        onProgressChanged?(0, nil)
    }

    /// Rebuilds this view from the always-on timeline, including timings that
    /// arrived before the Reader window was opened.
    func syncFromTimeline() {
        guard let utterance = timeline.current else { return }

        let documentChanged = chunks != utterance.chunks
        resetPlaybackTracking(clearCurrentChunk: true, resetPosition: true)
        if documentChanged {
            setDocument(chunks: utterance.chunks)
        }

        currentChunkIndex = utterance.baseIndex
        lastKnownPosition = engine.playbackPosition ?? 0

        for globalIndex in utterance.timings.keys.sorted() {
            guard let timing = utterance.timings[globalIndex] else { continue }
            receive(timing, globalIndex: globalIndex, updateAfterAlignment: false)
        }

        if engine.isSpeaking {
            setState(engine.isPaused ? .paused : .playing)
        } else {
            setState(.idle)
        }

        if documentChanged {
            onDocumentChanged?()
        }

        if engine.isSpeaking {
            updatePosition()
            startPositionTimer()
        } else {
            if let chunkIndex = chunkIndex(at: lastKnownPosition) {
                currentChunkIndex = chunkIndex
            }
            setActiveWord(nil)
            onProgressChanged?(lastKnownPosition, currentChunkIndex)
        }
    }

    func play(fromChunk requestedIndex: Int) {
        guard !chunks.isEmpty else { return }
        let index = min(max(requestedIndex, 0), chunks.count - 1)

        do {
            try timeline.replay(fromChunk: index, fallbackChunks: chunks)
        } catch {
            transitionToIdle(clearCurrentChunk: false, resetPosition: true)
            oratorLog("reader speak FAILED: \(error.localizedDescription)")
        }
    }

    func togglePlayPause() {
        switch state {
        case .idle:
            play(fromChunk: currentChunkIndex ?? 0)
        case .playing:
            engine.pause()
            setState(.paused)
        case .paused:
            engine.resume()
            setState(.playing)
        }
    }

    func skip(by offset: Int) {
        guard !chunks.isEmpty else { return }
        let origin = currentChunkIndex ?? 0
        play(fromChunk: min(max(origin + offset, 0), chunks.count - 1))
    }

    func stop() {
        engine.stop()
        finishCurrentUtterance()
    }

    func chunkIndex(containingCharacterAt location: Int) -> Int? {
        guard location >= 0 else { return nil }

        var lowerBound = 0
        var upperBound = chunkRanges.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            let range = chunkRanges[midpoint]
            if location < range.location {
                upperBound = midpoint
            } else if location >= NSMaxRange(range) {
                lowerBound = midpoint + 1
            } else {
                return midpoint
            }
        }
        return nil
    }

    /// Closing the Reader tears down view-only work without changing playback.
    func cleanup() {
        invalidatePositionTimer()
        setActiveWord(nil)
        setState(.idle)
    }

    private func setDocument(chunks: [String]) {
        self.chunks = chunks
        text = chunks.joined(separator: " ")
        chunkRanges = Self.ranges(for: chunks)
    }

    private static func ranges(for chunks: [String]) -> [NSRange] {
        var ranges: [NSRange] = []
        ranges.reserveCapacity(chunks.count)

        var utf16Location = 0
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { utf16Location += 1 }
            let length = chunk.utf16.count
            ranges.append(NSRange(location: utf16Location, length: length))
            utf16Location += length
        }
        return ranges
    }

    private func observeSpeechNotifications() {
        let center = NotificationCenter.default
        // Keep the Reader's play/pause state in sync when speech is paused or
        // resumed from outside the window (global pause hotkey, menu item).
        notificationObservers.append(center.addObserver(
            forName: .oratorSpeechPaused,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .playing else { return }
                self.setState(.paused)
            }
        })

        notificationObservers.append(center.addObserver(
            forName: .oratorSpeechResumed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .paused else { return }
                self.setState(.playing)
            }
        })
    }

    private func receive(_ event: SpeechTimeline.Event) {
        switch event {
        case .utteranceStarted:
            guard let utterance = timeline.current else { return }
            let documentChanged = chunks != utterance.chunks

            resetPlaybackTracking(clearCurrentChunk: true, resetPosition: true)
            if documentChanged {
                setDocument(chunks: utterance.chunks)
            }
            currentChunkIndex = utterance.baseIndex
            setState(.playing)

            if documentChanged {
                onDocumentChanged?()
            }
            onProgressChanged?(0, currentChunkIndex)
            startPositionTimer()

        case .chunkTimed(let globalIndex):
            guard let timing = timeline.current?.timings[globalIndex] else { return }
            receive(timing, globalIndex: globalIndex)

        case .utteranceEnded:
            finishCurrentUtterance()
        }
    }

    private func receive(
        _ timing: ChunkTiming,
        globalIndex globalChunkIndex: Int,
        updateAfterAlignment: Bool = true
    ) {
        guard chunks.indices.contains(globalChunkIndex),
              chunkRanges.indices.contains(globalChunkIndex),
              let displayChunkRange = Range(chunkRanges[globalChunkIndex], in: text)
        else { return }

        timedChunks.removeAll { $0.index == globalChunkIndex }
        timedChunks.append(TimedChunk(
            index: globalChunkIndex,
            start: timing.offset,
            end: timing.offset + timing.duration
        ))
        timedChunks.sort { $0.start < $1.start }

        alignedWords.removeAll { $0.chunkIndex == globalChunkIndex }
        var cursor = displayChunkRange.lowerBound
        for word in timing.words {
            guard let wordStart = word.start,
                  let wordEnd = word.end,
                  !word.text.isEmpty,
                  cursor < displayChunkRange.upperBound
            else { continue }

            guard let match = text.range(
                of: word.text,
                options: [.literal],
                range: cursor..<displayChunkRange.upperBound
            ) else {
                continue
            }

            alignedWords.append(AlignedWord(
                characterRange: NSRange(match, in: text),
                start: timing.offset + wordStart,
                end: timing.offset + wordEnd,
                chunkIndex: globalChunkIndex
            ))
            cursor = match.upperBound
        }
        alignedWords.sort {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }

        if updateAfterAlignment {
            updatePosition()
        }
    }

    private func startPositionTimer() {
        invalidatePositionTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePosition()
            }
        }
        positionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func invalidatePositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func updatePosition() {
        if let position = engine.playbackPosition {
            lastKnownPosition = position
        }

        if let chunkIndex = chunkIndex(at: lastKnownPosition), chunkIndex != currentChunkIndex {
            currentChunkIndex = chunkIndex
        }
        setActiveWord(activeWord(at: max(0, lastKnownPosition - Self.highlightLatencyCompensation)))
        onProgressChanged?(lastKnownPosition, currentChunkIndex)
    }

    private func activeWord(at position: TimeInterval) -> AlignedWord? {
        var lowerBound = 0
        var upperBound = alignedWords.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if alignedWords[midpoint].start <= position {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        guard lowerBound > 0 else { return nil }
        let candidate = alignedWords[lowerBound - 1]
        return position < candidate.end ? candidate : nil
    }

    private func chunkIndex(at position: TimeInterval) -> Int? {
        var lowerBound = 0
        var upperBound = timedChunks.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if timedChunks[midpoint].start <= position {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        guard lowerBound > 0 else { return nil }
        let candidate = timedChunks[lowerBound - 1]
        return position < candidate.end ? candidate.index : nil
    }

    private func setActiveWord(_ word: AlignedWord?) {
        guard activeWord?.characterRange != word?.characterRange else { return }
        activeWord = word
        onActiveWordChanged?(word?.characterRange)
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChanged?(newState)
    }

    private func resetPlaybackTracking(clearCurrentChunk: Bool, resetPosition: Bool) {
        invalidatePositionTimer()
        alignedWords.removeAll(keepingCapacity: true)
        timedChunks.removeAll(keepingCapacity: true)
        setActiveWord(nil)
        if clearCurrentChunk { currentChunkIndex = nil }
        if resetPosition { lastKnownPosition = 0 }
    }

    private func finishCurrentUtterance() {
        invalidatePositionTimer()
        setActiveWord(nil)
        setState(.idle)
        onProgressChanged?(lastKnownPosition, currentChunkIndex)
    }

    private func transitionToIdle(clearCurrentChunk: Bool, resetPosition: Bool) {
        resetPlaybackTracking(
            clearCurrentChunk: clearCurrentChunk,
            resetPosition: resetPosition
        )
        setState(.idle)
        onProgressChanged?(lastKnownPosition, currentChunkIndex)
    }
}
